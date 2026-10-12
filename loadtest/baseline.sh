#!/usr/bin/env bash
# Baseline of ONE pod (same image, resources and limits as the chart, no HPA) through Traefik.
# For each fixed arrival rate it prints achieved RPS, latency percentiles, failures and the pod's CPU.
# Rate 0 means a single sequential virtual user (pure per-request latency).
#
# Run (about 4 minutes, uses a temporary namespace `baseline` that it deletes at the end):
#   docker compose exec -T toolbox bash /workspace/loadtest/baseline.sh | tee loadtest/evidence/baseline.txt
set -euo pipefail
export KUBECONFIG=/kube/config
NS=baseline
# Keep this tag in sync with chart/quote-api/values.yaml (the build with a fixed amount of CPU work per request).
IMG="${IMG:-ghcr.io/onlylight/devops-takehome-solution/quote-api:sha-037670c7999585b738119349795dc24bf3f9669a}"
RATES="${RATES:-0 1 2 3 4 5 6 8}"
trap 'kubectl delete ns $NS --wait=false >/dev/null 2>&1 || true' EXIT

kubectl delete ns $NS --ignore-not-found --wait=true >/dev/null
kubectl create ns $NS >/dev/null
kubectl apply -n $NS -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: base}
spec:
  replicas: 1
  selector: {matchLabels: {app: base}}
  template:
    metadata: {labels: {app: base}}
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms: [{matchExpressions: [{key: acme.io/capacity, operator: In, values: [spot, on-demand]}]}]
      containers:
      - name: c
        image: $IMG
        ports: [{name: http, containerPort: 8080}]
        readinessProbe: {httpGet: {path: /readyz, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 300m, memory: 64Mi}, limits: {cpu: 500m, memory: 128Mi}}
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Service
metadata: {name: base}
spec: {selector: {app: base}, ports: [{name: http, port: 80, targetPort: http}]}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: base}
spec:
  ingressClassName: traefik
  rules:
  - host: baseline.localhost
    http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: base, port: {name: http}}}}]}
EOF
kubectl -n $NS rollout status deploy/base --timeout=120s >/dev/null
echo "pod on: $(kubectl -n $NS get pod -l app=base -o jsonpath='{.items[0].spec.nodeName}')   (requests 300m / limit 500m CPU)"
sleep 8   # let Traefik pick up the new route

cat > /tmp/b.js <<'JS'
import http from 'k6/http';
import { check } from 'k6';
const RATE = Number(__ENV.RATE || 0);
export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  ...(RATE === 0
    ? { vus: 1, duration: '20s' }
    : { scenarios: { r: { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: '20s', preAllocatedVUs: 60, maxVUs: 300 } } }),
};
export default function () {
  const r = http.get('http://k3d-itv-serverlb/api/quote', { headers: { Host: 'baseline.localhost' }, timeout: '10s' });
  check(r, { ok: (x) => x.status === 200 });
}
export function handleSummary(data) { return { '/tmp/s.json': JSON.stringify(data) }; }
JS

printf '%-7s %-9s %-7s %-7s %-7s %-8s %-8s %s\n' "target" "achieved" "p50ms" "p95ms" "p99ms" "failed%" "dropped" "podCPU (top)"
for RATE in $RATES; do
  rm -f /tmp/s.json
  k6 run -q -e RATE=$RATE /tmp/b.js >/dev/null 2>&1 &
  K6=$!
  sleep 14
  CPU=$(kubectl -n $NS top pod -l app=base --no-headers 2>/dev/null | awk '{print $2}' || true)  # metrics lag: may be empty
  wait $K6 || true
  jq -r --arg rate "$RATE" --arg cpu "${CPU:-?}" '
    .metrics as $m
    | [ $rate,
        ((($m.http_reqs.values.rate // 0) * 10 | round) / 10 | tostring),
        (($m.http_req_duration.values.med // 0) | round | tostring),
        (($m.http_req_duration.values["p(95)"] // 0) | round | tostring),
        (($m.http_req_duration.values["p(99)"] // 0) | round | tostring),
        ((($m.http_req_failed.values.rate // 0) * 1000 | round) / 10 | tostring),
        (($m.dropped_iterations.values.count // 0) | tostring),
        $cpu ] | @tsv' /tmp/s.json | awk -F'\t' '{printf "%-7s %-9s %-7s %-7s %-7s %-8s %-8s %s\n",$1,$2,$3,$4,$5,$6,$7,$8}'
  sleep 3
done
