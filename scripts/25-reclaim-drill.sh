#!/usr/bin/env bash
# Spot-reclaim drill: drain a node that hosts the app while a curl loop hits the Ingress, show the
# pods rescheduling, assert the service never failed, then uncordon. Safe to re-run.
#
#   25-reclaim-drill.sh        # default: drain a SPOT node (a spot reclaim)
#   25-reclaim-drill.sh od     # drain the ON-DEMAND node (proves a lost on-demand domain does not strand pods)
#
# Env: MAX_FAILURES (default 0) failed requests tolerated during the whole drill (including the rebalance).
# The drill leaves the app in its intended state (>=1 replica on on-demand) and every node schedulable.
. "$(dirname "$0")/lib/common.sh"
need kubectl jq curl
require_cluster

NS=quote-api
APP=app.kubernetes.io/name=quote-api
MAX_FAILURES="${MAX_FAILURES:-0}"
case "${1:-spot}" in
  spot)         CAP=spot ;;
  od|on-demand) CAP=on-demand ;;
  *) die "usage: $0 [spot|od]" ;;
esac

NODE=""; LOOP_PID=""; LOG=$(mktemp)
cleanup() {
  [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null || true
  # Always give the node back, even if an assertion failed half way.
  [ -n "$NODE" ] && kubectl uncordon "$NODE" >/dev/null 2>&1 || true
  rm -f "$LOG"
}
trap cleanup EXIT

ready()   { kubectl -n "$NS" get deploy quote-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null | sed 's/^$/0/'; }
pending() { kubectl -n "$NS" get pods -l "$APP" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' '; }
min_replicas() { kubectl -n "$NS" get hpa quote-api -o jsonpath='{.spec.minReplicas}'; }

od_running() { placement_table | awk -F'\t' '$3 == "on-demand" && $4 == "Running"' | wc -l | tr -d ' '; }

# The spread rules only act when a pod is placed; the scheduler never moves running pods back after
# a node returns, so an app can end up entirely on spot. A rolling restart places a fresh generation
# under the full constraints and restores >=1 replica on on-demand. (Prod: descheduler / Karpenter.)
rebalance() {
  kubectl -n "$NS" rollout restart deploy/quote-api >/dev/null
  kubectl -n "$NS" rollout status deploy/quote-api --timeout=180s >/dev/null
  sleep 3
}

[ "$(ready)" -ge "$(min_replicas)" ] || die "app is not healthy yet (ready=$(ready)); run scripts/20-deploy.sh first"
if [ "$(od_running)" = 0 ]; then
  log "precondition: no replica on on-demand (an earlier drill left the app all-spot); rebalancing first"
  rebalance
fi

# ---- pick the node -------------------------------------------------------------------------
# Traefik has a single replica in k3s: draining its node would break the Ingress for reasons that
# have nothing to do with the app, so prefer a target that does not host it (and say so).
traefik_node=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
cands=$(kubectl -n "$NS" get pods -l "$APP" -o json | jq -r --arg cap "$CAP" --argjson n "$(kubectl get nodes -o json)" '
  ($n.items | map({(.metadata.name): (.metadata.labels["acme.io/capacity"] // "-")}) | add) as $m
  | [.items[].spec.nodeName] | group_by(.) | map({node: .[0], pods: length})
  | map(select($m[.node] == $cap)) | sort_by(-.pods) | .[] | "\(.node) \(.pods)"')
[ -n "$cands" ] || die "no $CAP node currently hosts the app"
NODE=$(echo "$cands" | awk -v t="$traefik_node" '$1 != t {print $1; exit}')
if [ -z "$NODE" ]; then
  NODE=$(echo "$cands" | awk 'NR==1 {print $1}')
  warn "the only candidate ($NODE) also hosts Traefik (single replica): failures may come from the Ingress, not the app"
fi
log "mode=$CAP  target node=$NODE  (Traefik is on ${traefik_node:-?})"

log "BEFORE (pod -> node -> capacity):"
placement_table

# ---- load ----------------------------------------------------------------------------------
( while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$INGRESS_URL/api/quote" || echo 000)
    echo "$(date +%T) $code" >>"$LOG"
    sleep 0.1
  done ) &
LOOP_PID=$!
sleep 3
log "curl loop running ($(wc -l <"$LOG" | tr -d ' ') requests so far, failures: $(grep -vc ' 200$' "$LOG" || true))"

# ---- drain ---------------------------------------------------------------------------------
log "cordon + drain $NODE (honours the PodDisruptionBudget)"
kubectl cordon "$NODE" >/dev/null
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s 2>&1 | grep -E 'evicting pod|evicted|drained|error|Error|cannot' || true

log "waiting for the app to be back at >= $(min_replicas) Ready pods, none Pending"
for _ in $(seq 1 60); do
  [ "$(ready)" -ge "$(min_replicas)" ] && [ "$(pending)" = 0 ] && break
  sleep 2
done

log "DURING the drain (node cordoned):"
placement_table
log "recent scheduling events:"
kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -E 'Scheduled|FailedScheduling|Killing|Evicted' | tail -8 || true

# ---- assertions ----------------------------------------------------------------------------
rc=0
[ "$(ready)" -ge "$(min_replicas)" ] || { warn "only $(ready) Ready pods (< $(min_replicas))"; rc=1; }
[ "$(pending)" = 0 ] || { warn "$(pending) pod(s) stuck Pending: the placement constraint blocked rescheduling"; rc=1; }
on_node=$(kubectl -n "$NS" get pods -l "$APP" --field-selector "spec.nodeName=$NODE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$on_node" = 0 ] || { warn "$on_node pod(s) still on the drained node"; rc=1; }
odpods=$(placement_table | awk -F'\t' '$3 == "on-demand" && $4 == "Running"' | wc -l | tr -d ' ')
badpods=$(placement_table | awk -F'\t' 'NR > 1 && $3 != "spot" && $3 != "on-demand"' | wc -l | tr -d ' ')
[ "$badpods" = 0 ] || { warn "$badpods pod(s) on a node with no capacity label (gpu/control-plane)"; rc=1; }
if [ "$CAP" = spot ]; then
  [ "$odpods" -ge 1 ] || { warn "no replica on on-demand after the spot drain"; rc=1; }
fi

# ---- give the node back --------------------------------------------------------------------
log "uncordon $NODE"
kubectl uncordon "$NODE" >/dev/null
NODE=""
sleep 3
log "AFTER uncordon, BEFORE rebalance: the scheduler never moves running pods back by itself"
placement_table

log "rebalancing with a rolling restart (the curl loop keeps running through it)"
rebalance
[ "$(od_running)" -ge 1 ] || { warn "no replica on on-demand after the rebalance"; rc=1; }
kill "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""

total=$(wc -l <"$LOG" | tr -d ' ')
bad=$(grep -vc ' 200$' "$LOG" || true)
log "curl loop: $total requests, $bad not HTTP 200"
[ "$bad" = 0 ] || { grep -v ' 200$' "$LOG" | head -5 >&2; }
[ "$bad" -le "$MAX_FAILURES" ] || { warn "$bad failed request(s), allowed $MAX_FAILURES"; rc=1; }

log "FINAL state (all nodes schedulable, spread restored):"
kubectl get nodes -L acme.io/capacity -L acme.io/node-type
placement_table
[ "$rc" = 0 ] && log "DRILL PASSED ($CAP)" || { warn "DRILL FAILED ($CAP)"; exit 1; }
