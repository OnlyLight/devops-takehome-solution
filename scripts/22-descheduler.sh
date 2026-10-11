#!/usr/bin/env bash
# Install the descheduler so the spot/on-demand spread is restored after HPA scale-down (see descheduler/values.yaml
# for why this is needed). Safe to re-run.
. "$(dirname "$0")/lib/common.sh"
need helm kubectl
require_cluster

DESCHEDULER_CHART_VERSION="${DESCHEDULER_CHART_VERSION:-0.37.0}"

log "installing descheduler chart $DESCHEDULER_CHART_VERSION into kube-system"
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/ --force-update >/dev/null
helm upgrade --install descheduler descheduler/descheduler \
  --version "$DESCHEDULER_CHART_VERSION" \
  --namespace kube-system \
  --values /workspace/descheduler/values.yaml \
  --wait --timeout 5m

log "descheduler is running (it checks every 2 minutes):"
kubectl -n kube-system get deploy descheduler --no-headers
