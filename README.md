# DevOps take-home: quote-api on k3d, ArgoCD and spot/on-demand placement

A small CPU-bound Go service (`quote-api`) on a local k3d cluster, deployed by ArgoCD with spot/on-demand placement, an HPA, Prometheus and Grafana, a k6 load test and a latency alert. After the quick start you have the running cluster, the service at `localhost:8080`, and the evidence that it scales and survives losing a node.

## Quick start

Prerequisites: Docker (Desktop on Windows/macOS, with about 10 GB of RAM given to it) and a free host port 8080.

```bash
git clone https://github.com/OnlyLight/devops-takehome-solution && cd devops-takehome-solution
docker compose up -d
./scripts/run-all.sh        # about 15 minutes the first time, about 3 minutes on a second run; add --full for the 6-minute load test
```

Then, from the host:

| What | Where |
|---|---|
| The service | `curl http://localhost:8080/api/quote` |
| Grafana (dashboard "quote-api: load and scaling") | http://grafana.localhost:8080 (user `admin`, password: `docker compose exec toolbox kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' \| base64 -d`) |
| ArgoCD UI | not exposed; see Troubleshooting notes |

Image: `ghcr.io/onlylight/devops-takehome-solution/quote-api:sha-<git sha>` (public, linux/amd64 and linux/arm64).

## Architecture overview

| Layer | What it is | Where |
|---|---|---|
| Harness | `docker compose up -d` starts a one-shot `bootstrap` (creates the cluster, labels the nodes) and a `toolbox` container with kubectl, helm, k6 and k3d; both talk to the host's Docker through `docker.sock` | `docker-compose.yml`, `toolbox/`, `scripts/00-cluster.sh`, `scripts/05-prepare-nodes.sh` |
| Cluster | k3d: 1 control-plane node and 4 agents: 2 spot and 1 on-demand (label `acme.io/capacity`) and 1 GPU node (tainted) | `scripts/00-cluster.sh` |
| Build | GitHub Actions runs the tests, builds a multi-arch image and pushes it to GHCR tagged `sha-<git sha>` | `.github/workflows/ci.yml`, `app/` |
| Delivery | ArgoCD syncs the Helm chart from this repo into the `quote-api` namespace (automated, prune, selfHeal) | `argocd/`, `scripts/20-deploy.sh`, `chart/quote-api/` |
| The service | `quote-api` (Go): `/api/quote`, `/healthz`, `/readyz`, `/metrics`; HPA 3 to 8 replicas at 60% of a 300m CPU request, PodDisruptionBudget, spot-preferred placement with at least one replica on on-demand | `chart/quote-api/` |
| Placement repair | the descheduler puts the on-demand replica back after an HPA scale-down | `descheduler/`, `scripts/22-descheduler.sh` |
| Observability | kube-prometheus-stack (Prometheus, Grafana, kube-state-metrics); a ServiceMonitor scrapes `/metrics`; a PrometheusRule holds the latency alert; the dashboard is loaded from a ConfigMap; no Alertmanager | `monitoring/`, `scripts/40-monitoring.sh`, `chart/quote-api/templates/` |
| Load test | k6 through the Ingress while a script records HPA scaling, placement and the alert state | `loadtest/`, `scripts/60-loadtest.sh` |

## Architecture

```mermaid
flowchart LR
  subgraph Host["Reviewer host"]
    C["docker compose up -d"]
    B["browser / curl :8080"]
  end
  C --> BOOT["bootstrap (one-shot): 00-cluster + 05-prepare-nodes"]
  C --> TB["toolbox: kubectl helm k6 k3d terraform"]
  BOOT -- "docker.sock" --> K3D
  subgraph K3D["k3d cluster on network itv-net"]
    LB["serverlb (nginx :80, :6443)"]
    S["server-0 (control plane)"]
    A0["agent-0 spot"]
    A1["agent-1 spot"]
    A2["agent-2 on-demand"]
    A3["agent-3 gpu (tainted)"]
    TR["Traefik (Ingress)"]
    APP["quote-api pods (HPA 3-8)"]
    ARGO["ArgoCD"]
    DESCH["descheduler"]
    MON["Prometheus + Grafana"]
    LB --> TR --> APP
    ARGO -- "syncs chart/quote-api" --> APP
    DESCH -. "restores the on-demand replica" .-> APP
    MON -. "scrapes /metrics" .-> APP
  end
  GH[("public GitHub repo")] --> ARGO
  GHCR[("GHCR image by git SHA")] --> APP
  B --> LB
  TB -- "kubeconfig via serverlb:6443" --> LB
```

A request to host `:8080` goes to `serverlb` (an nginx TCP proxy), then to the `svclb-traefik` pod on a node, then Traefik, which routes by the Ingress to the `quote-api` Service and a pod. Pods may use only the spot and on-demand agents: the GPU node (tainted) and the control plane are excluded by required node affinity.

## Script reference

| Script | What it does | When |
|---|---|---|
| `run-all.sh` | runs every numbered script below in order, stops at the first failure, prints a summary | the one command to run |
| `00-cluster.sh` | creates the k3d cluster (1 server, 4 agents) and writes the kubeconfig the toolbox uses | bootstrap (done by compose) |
| `05-prepare-nodes.sh` | runs the provided `prepare.sh`, then asserts 2 spot / 1 on-demand / 1 gpu | bootstrap |
| `20-deploy.sh` | installs ArgoCD and creates the Application that syncs `chart/quote-api` from this repo | after bootstrap |
| `22-descheduler.sh` | installs the descheduler that restores the on-demand replica after HPA scale-down | after 20 |
| `25-reclaim-drill.sh [spot\|od]` | drains a node that hosts the app under a curl loop, checks nothing fails, uncordons, rebalances | to prove the spot-reclaim survival |
| `30-troubleshoot.sh [--broken]` | applies the fixed (or the original broken) Part 3 manifests and runs `verify.sh` | Part 3 |
| `40-monitoring.sh` | installs Prometheus + Grafana and loads the dashboard | before the load test |
| `60-loadtest.sh` | k6 through the Ingress while recording HPA scaling, placement and the alert state | Part 6 |
| `lib/common.sh` | shared helpers (logging, `placement_table`) | sourced by the others |

## Design decisions and trade-offs

- **Placement (Part 2).** Required node affinity on the capacity label, a preference for spot, a hard topology spread across the two capacity domains (`maxSkew: 2`, `nodeTaintsPolicy: Honor`, `matchLabelKeys: pod-template-hash`) and a soft spread across hostnames. The spot preference favours spot, the hard spread guarantees a replica on on-demand when pods are placed, and the hostname spread stops two pods stacking on one node. With the default `nodeTaintsPolicy` a cordoned node still counts in the skew and a pod stays Pending (control experiment: 1 Pending with the default, 3 Running with `Honor`). Cost: above 3 replicas the extras spill to on-demand (5 spot + 3 on-demand at 8 replicas).
- **The descheduler.** HPA scale-down left 3 spot + 0 on-demand in 2 of 3 cycles, because topologySpread only acts when a pod is placed. The descheduler sees skew 3 > `maxSkew` 2 and evicts a spot pod, so its replacement must go to on-demand. The policy is narrow (one plugin, only `quote-api`, `nodeFit`, PDB respected). Recovery from a deliberately created (3, 0) state took 51 s; I have not yet watched it fix a natural scale-down.
- **GitOps flow.** ArgoCD (automated, prune, selfHeal) syncs the chart from Git. A new image needs two commits (build, then bump the tag, which must already exist on GHCR). The Deployment has no `replicas` because the HPA owns it and selfHeal would revert it.
- **The service.** Each request does a fixed amount of SHA-256 work, calibrated at start-up to about 100 ms of CPU. The first version spun for 100 ms of wall clock, so a pod limited to 0.5 core served 40 req/s with no errors and could never saturate.
- **Load test and observability.** k6 uses an open model (fixed arrival rate); the thresholds sit between a healthy run and a collapsed one from a one-pod baseline; the alert is on latency because a saturated service answers slowly instead of returning 5xx. See `LOADTEST.md`.
- **Chart security context.** Non-root, read-only root filesystem (required by the task) plus no privilege escalation, all capabilities dropped and the RuntimeDefault seccomp profile (extras, marked in the chart). Together they pass the Pod Security `restricted` profile (checked with a server dry run, with a bad Deployment as a negative control); the app only listens on 8080, so it needs no capability.

## What I cut, and why

Of the optional tracks (Parts 4 to 6) I chose Part 6 (monitoring, load test, observability) first because it is the area I have had the least hands-on exposure to, so it was where I could learn the most, and I preferred one track done in depth over three done thinly. The rest was cut for time.

| Cut | Why |
|---|---|
| Part 4 (GitHub Actions migration with a hard-failing SAST gate) | I chose Part 6 as the track. `ci.yml` is a minimal pipeline (vet and test with `-race`, multi-arch build pushed by git SHA); the legacy GitLab file is not migrated and there is no SAST gate. |
| Part 5 (Karpenter and Cloudflare Terraform, validate-only) | It only checks that the files are well-formed (`terraform validate`), not that they work on a real EKS cluster or Cloudflare zone, so I would learn less from it than from Part 6, where I could measure real behaviour. |
| Alertmanager | The task needs an alert rule, not a notification channel; dropping it saves memory. The alert is visible in Prometheus, nobody is notified. |
| TLS on the Ingress, cosign, tracing, multi-environment values | Gold-plating, which the task says not to do. |
| ArgoCD UI exposure, a second Traefik replica | The UI is reachable by port-forward (below). Traefik is the k3s built-in with one replica: a single point of failure for incoming traffic that I accepted for a local harness. |

## Troubleshooting notes (reviewer machine)

- **Port 8080 is taken.** `HOST_PORT=8081 docker compose up -d` (set it before the first `up`; see `.env.example`).
- **Not enough memory.** The stack needs about 10 GB for Docker: Docker Desktop on Windows uses WSL2, give it memory in `%UserProfile%\.wslconfig` (`[wsl2] memory=10GB`), then `wsl --shutdown`.
- **Windows/Git Bash.** Scripts are bind-mounted into Linux containers, so line endings must be LF (`.gitattributes` enforces it); Git Bash rewrites `/scripts/...` into a Windows path unless `MSYS_NO_PATHCONV=1` (`run-all.sh` sets it).
- **Apple Silicon / arm64.** The toolbox and the app image are built for amd64 and arm64.
- **Start over.** `docker compose down -v` does not delete the cluster (k3d owns it): `docker compose exec toolbox k3d cluster delete itv`, then `docker compose down -v` and `docker compose up -d`.
- **ArgoCD UI.** Not exposed. From the host: create a kubeconfig for the host (`docker compose exec -T toolbox k3d kubeconfig get itv`, replace the `server:` host with `127.0.0.1`) and `kubectl -n argocd port-forward svc/argocd-server 8081:443`.

## Findings in the provided files (imperfect handoff)

| File | Finding | What I did |
|---|---|---|
| `prepare.sh` | needs `kubectl` and a working kubeconfig inside the toolbox (not stated); says "Run ONCE" but is idempotent (`--overwrite`); assigns roles by alphabetical node order | wired the kubeconfig in `00-cluster.sh`, run it unmodified, then assert 2 spot / 1 on-demand / 1 gpu in `05-prepare-nodes.sh` |
| the control-plane node | schedulable and unlabeled, so any pod without affinity can land on it | the chart's required node affinity excludes it |
| `verify.sh` | passes only on the NAME of `default-deny`, not on it still denying everything; waits 60 s per rollout | kept it unmodified; `30-troubleshoot.sh` waits for the rollouts first; negative tests added in `TROUBLESHOOTING.md` |
| `verify.sh` smoke step | can print PASS without the DNS allow rule, because the first name lookup can win a start-up race | added the DNS rule anyway; documented in `TROUBLESHOOTING.md` |
| the task | does not say how to run k3d inside compose (docker.sock, ports, CRLF, arm64) | designed it in `docker-compose.yml` and the toolbox image |
| Part 2 vs Part 3 | the node label is `acme.io/node-type`, `broken-app.yaml` selects `node-type` | fixed the workload, never the node |
| `ci/legacy.gitlab-ci.yml` | contains AWS's documented example keys (`AKIAIOSFODNN7EXAMPLE`), which the file itself says are not live credentials; a secret scanner may still flag them | left the provided file unmodified; a scan of the whole Git history for keys and tokens found nothing else |

## More

- `TROUBLESHOOTING.md`: Part 3, one entry per fault.
- `LOADTEST.md`: Part 6 results and what they mean.
- `OPS-ANSWERS.md`: Part 7.
- `AI-USAGE.md`: how AI was used and where it was wrong.
- `VERSIONS.md`: every pinned version and where it was checked.
