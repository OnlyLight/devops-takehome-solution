#!/usr/bin/env bash
# Run the provided troubleshoot/prepare.sh (unmodified) to simulate the nodepools, then assert
# the result instead of trusting it: prepare.sh assigns roles by alphabetical node order and
# its error message is misleading on an empty node list. Safe to re-run (labels use --overwrite).
. "$(dirname "$0")/lib/common.sh"
need kubectl
require_cluster

log "running troubleshoot/prepare.sh"
sh /workspace/troubleshoot/prepare.sh

count() { kubectl get nodes -l "$1" --no-headers 2>/dev/null | wc -l | tr -d ' '; }
spot=$(count acme.io/capacity=spot)
od=$(count acme.io/capacity=on-demand)
gpu=$(count acme.io/node-type=gpu)
[ "$spot" = 2 ] || die "expected 2 spot nodes, found $spot"
[ "$od" = 1 ]   || die "expected 1 on-demand node, found $od"
[ "$gpu" = 1 ]  || die "expected 1 gpu node, found $gpu"

gpu_node=$(kubectl get nodes -l acme.io/node-type=gpu -o jsonpath='{.items[0].metadata.name}')
kubectl get node "$gpu_node" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' \
  | grep -qx 'nvidia.com/gpu=true:NoSchedule' || die "gpu node $gpu_node is missing taint nvidia.com/gpu=true:NoSchedule"

# The server must not carry a nodepool label (otherwise workloads could be pinned to it by accident).
kubectl get nodes -l 'node-role.kubernetes.io/control-plane,acme.io/capacity' --no-headers 2>/dev/null | grep -q . \
  && die "control-plane node got a capacity label"

log "OK: 2 spot, 1 on-demand, 1 gpu (tainted)"
