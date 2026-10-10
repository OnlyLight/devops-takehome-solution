#!/usr/bin/env bash
# Shared helpers. Source from scripts: . "$(dirname "$0")/lib/common.sh"
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-itv}"
HOST_PORT="${HOST_PORT:-8080}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}"
AGENTS="${AGENTS:-4}"
export KUBECONFIG="${KUBECONFIG:-/kube/config}"

# Inside the toolbox "localhost" is the container, not the host: reach the Ingress via the k3d load balancer.
INGRESS_URL="http://k3d-${CLUSTER_NAME}-serverlb"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(basename "$0")" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(basename "$0")" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c (run inside the toolbox: docker compose exec toolbox ...)"; done; }

# Fail early with a useful message if the cluster is not reachable.
require_cluster() {
  kubectl version >/dev/null 2>&1 || die "cannot reach the cluster with KUBECONFIG=$KUBECONFIG. Run: docker compose up -d (bootstrap creates it)"
}
