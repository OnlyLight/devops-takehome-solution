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

# Pod -> node -> capacity table for the app. Used by the deploy, drill and load-test scripts as
# placement evidence (nodes with no capacity label, e.g. gpu/control-plane, show their node-type or "-").
placement_table() {
  local ns="${1:-quote-api}" nodes
  nodes=$(kubectl get nodes -o json)
  printf 'POD\tNODE\tCAPACITY\tPHASE\n'
  kubectl get pods -n "$ns" -l app.kubernetes.io/name=quote-api -o json | jq -r --argjson n "$nodes" '
    ($n.items | map({(.metadata.name): (.metadata.labels["acme.io/capacity"] // .metadata.labels["acme.io/node-type"] // "-")}) | add) as $m
    | .items | sort_by(.spec.nodeName // "") | .[]
    | [.metadata.name, (.spec.nodeName // "<pending>"), ($m[(.spec.nodeName // "")] // "-"), .status.phase] | @tsv'
}

# Fail early with a useful message if the cluster is not reachable.
require_cluster() {
  kubectl version >/dev/null 2>&1 || die "cannot reach the cluster with KUBECONFIG=$KUBECONFIG. Run: docker compose up -d (bootstrap creates it)"
}
