#!/usr/bin/env bash
# Install a slim kube-prometheus-stack (Prometheus + Grafana) into the `monitoring` namespace, then make
# ArgoCD notice the new CRDs so the chart's ServiceMonitor is rendered. Safe to re-run.
. "$(dirname "$0")/lib/common.sh"
need helm kubectl curl
require_cluster

KPS_CHART_VERSION="${KPS_CHART_VERSION:-92.2.0}"
RELEASE=kps

log "installing kube-prometheus-stack $KPS_CHART_VERSION (release $RELEASE)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  --values /workspace/monitoring/kps-values.yaml \
  --wait --timeout 10m

# The dashboard JSON in the repo is the single source: wrap it in a ConfigMap labelled for Grafana's sidecar.
log "loading the quote-api dashboard (ConfigMap labelled grafana_dashboard=1)"
kubectl -n monitoring create configmap quote-api-dashboard --from-file=quote-api.json=/workspace/monitoring/dashboard.json \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f - >/dev/null

# ArgoCD caches the cluster's API list. The app chart renders its ServiceMonitor only when the
# monitoring.coreos.com API exists, so the cache must be refreshed after the CRDs appear.
if kubectl -n argocd get application quote-api >/dev/null 2>&1; then
  log "asking ArgoCD for a hard refresh of quote-api"
  kubectl -n argocd annotate application quote-api argocd.argoproj.io/refresh=hard --overwrite >/dev/null
fi

log "waiting for Grafana through the Ingress (Host: grafana.localhost)"
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: grafana.localhost' "$INGRESS_URL/login" || true)
  [ "$code" = 200 ] && break
  sleep 3
done
[ "$code" = 200 ] || die "Grafana did not answer HTTP 200 through the Ingress (last code: $code)"

log "OK. Open http://grafana.localhost:${HOST_PORT}  user: admin"
log "password: kubectl -n monitoring get secret ${RELEASE}-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
