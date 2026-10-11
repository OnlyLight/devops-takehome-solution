#!/usr/bin/env bash
# Load test with scaling proof. Runs loadtest/k6.js through the Ingress while recording how the HPA scales and
# where the new replicas are placed, then checks the result. Evidence goes to loadtest/evidence/.
#
#   60-loadtest.sh                          # PROFILE=load (default, ~6 min)
#   PROFILE=smoke P95_MS=50 60-loadtest.sh  # 30 s; proves the thresholds can fail (expected exit != 0)
#   PROFILE=stress 60-loadtest.sh           # keeps ramping to 50 req/s to find the collapse point (no thresholds)
#
# Fails (exit 1) when: a k6 threshold fails; (load/stress) the HPA never went above minReplicas; or any replica
# ever ran on a node without a capacity label (GPU / control-plane).
. "$(dirname "$0")/lib/common.sh"
need kubectl jq k6 curl
require_cluster

NS=quote-api
PROFILE="${PROFILE:-load}"
EV=/workspace/loadtest/evidence
mkdir -p "$EV"

kubectl -n argocd get application quote-api -o jsonpath='{.status.health.status}' 2>/dev/null | grep -q Healthy \
  || die "the app is not Healthy in ArgoCD; run scripts/20-deploy.sh first"
MIN=$(kubectl -n "$NS" get hpa quote-api -o jsonpath='{.spec.minReplicas}')

# "<current>\t<desired>\t<cpu%>\t<spot>\t<on-demand>\t<other>\t<pending>" for the app right now
snapshot() {
  local hpa nodes
  hpa=$(kubectl -n "$NS" get hpa quote-api -o jsonpath='{.status.currentReplicas}{"\t"}{.status.desiredReplicas}{"\t"}{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)
  nodes=$(kubectl get nodes -o json)
  printf '%s\t%s\n' "${hpa:-?}" "$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api -o json | jq -r --argjson n "$nodes" '
    ($n.items | map({(.metadata.name): (.metadata.labels["acme.io/capacity"] // "other")}) | add) as $m
    | [.items[] | select(.metadata.deletionTimestamp | not) | (if .spec.nodeName then $m[.spec.nodeName] else "pending" end)]
    | [(map(select(. == "spot")) | length), (map(select(. == "on-demand")) | length),
       (map(select(. == "other")) | length), (map(select(. == "pending")) | length)] | @tsv')"
}

# Start from a quiet HPA so the evidence shows the whole scale-out (scale-down waits ~5 min after load).
if [ "$PROFILE" != smoke ]; then
  log "waiting for the app to be at minReplicas=$MIN before starting (HPA scale-down can take ~5 min)"
  for _ in $(seq 1 90); do
    [ "$(kubectl -n "$NS" get hpa quote-api -o jsonpath='{.status.currentReplicas}')" = "$MIN" ] && break
    sleep 5
  done
fi

LOOP=""; WATCH=""
cleanup() { [ -n "$LOOP" ] && kill "$LOOP" 2>/dev/null || true; [ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null || true; }
trap cleanup EXIT

# 1) the raw "kubectl get hpa -w" stream, 2) a timestamped sample every 5 s that also counts pods per nodepool
kubectl -n "$NS" get hpa quote-api -w >"$EV/hpa-watch.txt" 2>&1 &
WATCH=$!
printf 'time\tcurrent\tdesired\tcpu%%\tspot\ton-demand\tother\tpending\n' >"$EV/hpa-timeline.tsv"
( while :; do printf '%s\t%s\n' "$(date +%T)" "$(snapshot)" >>"$EV/hpa-timeline.tsv"; sleep 5; done ) &
LOOP=$!

log "start state: $(snapshot | awk -F'\t' '{print "replicas=" $1 " cpu%=" $3 " spot=" $4 " on-demand=" $5}')"
log ">>> LOAD STARTED $(date +%T)  profile=$PROFILE. Take the Grafana screenshot now (http://grafana.localhost:${HOST_PORT}, 'Last 15 minutes')."
set +e
k6 run -e PROFILE="$PROFILE" -e BASE_URL="$INGRESS_URL" \
  -e P95_MS="${P95_MS:-500}" -e P99_MS="${P99_MS:-1500}" -e FAIL_RATE="${FAIL_RATE:-0.01}" \
  --summary-export "$EV/k6-summary.json" /workspace/loadtest/k6.js 2>&1 | tee "$EV/k6-output.txt"
K6_RC=${PIPESTATUS[0]}
set -e
log "<<< LOAD ENDED $(date +%T)  (k6 exit code $K6_RC)"
sleep 10
snapshot_line=$(snapshot); printf '%s\t%s\n' "$(date +%T)" "$snapshot_line" >>"$EV/hpa-timeline.tsv"
cleanup; LOOP=""; WATCH=""

kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -E 'SuccessfulRescale|ScalingReplicaSet|FailedGetResourceMetric' >"$EV/events.txt" || true
kubectl -n "$NS" describe hpa quote-api | sed -n '/^Events:/,$p' >>"$EV/events.txt" || true

# ---- verdict -------------------------------------------------------------------------------------
MAXREP=$(awk -F'\t' 'NR>1 && $2 ~ /^[0-9]+$/ {if ($2>m) m=$2} END {print m+0}' "$EV/hpa-timeline.tsv")
PEAK=$(awk -F'\t' -v m="$MAXREP" 'NR>1 && $2==m {print "spot=" $5 " on-demand=" $6 " pending=" $8; exit}' "$EV/hpa-timeline.tsv")
OTHER=$(awk -F'\t' 'NR>1 && $7 ~ /^[0-9]+$/ {if ($7>m) m=$7} END {print m+0}' "$EV/hpa-timeline.tsv")

echo
log "HPA timeline (changes only; full file: loadtest/evidence/hpa-timeline.tsv):"
awk -F'\t' 'NR==1 {print; next} {k=$2 FS $3 FS $5 FS $6; if (k != p) print; p=k}' "$EV/hpa-timeline.tsv"
echo
log "peak replicas: $MAXREP ($PEAK); minReplicas: $MIN; most pods ever on a node without a capacity label: $OTHER"
log "final placement (pod -> node -> capacity):"
placement_table

rc=0
[ "$K6_RC" = 0 ] || { warn "k6 exited $K6_RC: a threshold failed (or the run errored)"; rc=1; }
if [ "$PROFILE" != smoke ]; then
  [ "$MAXREP" -gt "$MIN" ] || { warn "the HPA never scaled above minReplicas ($MIN)"; rc=1; }
fi
[ "$OTHER" = 0 ] || { warn "a replica ran on a node without a capacity label (gpu/control-plane)"; rc=1; }
[ "$rc" = 0 ] && log "LOAD TEST PASSED ($PROFILE)" || warn "LOAD TEST FAILED ($PROFILE)"
exit "$rc"
