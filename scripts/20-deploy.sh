#!/usr/bin/env bash
# Install ArgoCD, then deploy the app ONLY through an ArgoCD Application that syncs chart/quote-api
# from this repo's public Git URL (no `helm install` of the app). Safe to re-run.
#
# Chicken-and-egg: ArgoCD pulls from GitHub, so the chart (and the image tag it references) must
# already be pushed to TARGET_REVISION. Override with REPO_URL / TARGET_REVISION for a fork or branch.
. "$(dirname "$0")/lib/common.sh"
need helm kubectl curl envsubst git jq
require_cluster

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.10.1}"
TARGET_REVISION="${TARGET_REVISION:-main}"

# ArgoCD runs in the cluster with no SSH key, so a public repo must be given as https://.
repo="${REPO_URL:-$(git -C /workspace remote get-url origin 2>/dev/null || true)}"
[ -n "$repo" ] || die "cannot determine the repo URL: set REPO_URL=https://github.com/<user>/<repo>.git"
REPO_URL=$(printf '%s' "$repo" | sed -E 's#^git@github\.com:#https://github.com/#; s#^ssh://git@github\.com/#https://github.com/#')
export REPO_URL TARGET_REVISION
log "ArgoCD will sync $REPO_URL @ $TARGET_REVISION (path chart/quote-api)"

log "installing ArgoCD chart $ARGOCD_CHART_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values /workspace/argocd/values.yaml \
  --wait --timeout 5m

log "applying the quote-api Application"
envsubst '${REPO_URL} ${TARGET_REVISION}' < /workspace/argocd/application.yaml.tpl | kubectl apply -f -

log "waiting for Synced + Healthy (up to 5 min)"
status() { kubectl -n argocd get application quote-api -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true; }
for _ in $(seq 1 60); do
  [ "$(status)" = "Synced Healthy" ] && break
  sleep 5
done
if [ "$(status)" != "Synced Healthy" ]; then
  kubectl -n argocd get application quote-api -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2 || true
  die "application is '$(status)', expected 'Synced Healthy' (see: kubectl -n argocd describe application quote-api)"
fi
log "application: $(status)"

log "calling the app through the Ingress ($INGRESS_URL/api/quote)"
for _ in $(seq 1 30); do
  out=$(curl -fsS --max-time 5 "$INGRESS_URL/api/quote" 2>/dev/null) && break
  sleep 2
done
[ -n "${out:-}" ] || die "no answer from $INGRESS_URL/api/quote"
echo "$out"

log "placement (pod -> node -> capacity):"
placement_table
log "OK. From the host: curl http://localhost:${HOST_PORT}/api/quote"
