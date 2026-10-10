#!/usr/bin/env bash
# Create (or reuse) the k3d cluster: 1 server + 4 agents on the compose network, then
# write a kubeconfig the toolbox can use. Safe to re-run.
. "$(dirname "$0")/lib/common.sh"
need k3d kubectl jq docker

NET=itv-net
LB="k3d-${CLUSTER_NAME}-serverlb"

docker info >/dev/null 2>&1 || die "cannot talk to Docker: is /var/run/docker.sock mounted and Docker running?"

if k3d cluster list -o json | jq -e --arg n "$CLUSTER_NAME" '.[] | select(.name == $n)' >/dev/null; then
  have=$(k3d cluster list -o json | jq -r --arg n "$CLUSTER_NAME" '.[] | select(.name == $n) | .agentsCount')
  [ "$have" = "$AGENTS" ] || die "cluster '$CLUSTER_NAME' exists with $have agents, expected $AGENTS. Recreate: k3d cluster delete $CLUSTER_NAME"
  log "cluster '$CLUSTER_NAME' already exists - making sure it is running"
  k3d cluster start "$CLUSTER_NAME" >/dev/null
else
  log "creating cluster '$CLUSTER_NAME' (1 server, $AGENTS agents, $K3S_IMAGE, host port $HOST_PORT -> ingress :80)"
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 --agents "$AGENTS" \
    --image "$K3S_IMAGE" \
    --network "$NET" \
    --port "${HOST_PORT}:80@loadbalancer" \
    --k3s-arg "--tls-san=${LB}@server:*" \
    --wait --timeout 300s
fi

# k3d generates a kubeconfig pointing at the host-published port (inside a container: host.docker.internal:<random-port>).
# That path depends on Docker Desktop and a random port; use the LB container name on the shared network instead.
mkdir -p "$(dirname "$KUBECONFIG")"
k3d kubeconfig get "$CLUSTER_NAME" \
  | sed -E "s#server: https://[^[:space:]]+#server: https://${LB}:6443#" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

log "waiting for $((AGENTS + 1)) nodes to be Ready"
for _ in $(seq 1 60); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge $((AGENTS + 1)) ] && break
  sleep 3
done
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes
