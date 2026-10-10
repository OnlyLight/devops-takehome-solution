# Pinned versions

Looked up from upstream release pages / registries on 2026-10-09 (not from memory). Bump deliberately, together with the toolbox image.

| Component | Pin | Source checked | Note |
|---|---|---|---|
| k3s (cluster image) | `rancher/k3s:v1.35.5-k3s1` | Docker Hub manifest: amd64+arm64 | k3d v5.9.0 reports this as its default k3s (`k3d version`, checked in the toolbox). Whether `nodeTaintsPolicy`/`nodeAffinityPolicy` behave as the placement design assumes is NOT yet verified: to be proven in the reclaim drill (M3.5), not assumed from docs/memory |
| k3d | `v5.9.0` | GitHub releases | |
| kubectl | `v1.35.5` | match cluster | within +-1 minor skew of server |
| helm | `v4.3.0` | GitHub releases | Helm 4; chart tooling checked when the toolbox is built |
| terraform | `v1.16.5` | GitHub releases | validate-only |
| k6 | `v2.3.0` | GitHub releases | |
| argo-cd chart | `10.10.1` (app `v3.5.4`) | argo-helm `Chart.yaml` | |
| kube-prometheus-stack chart | `92.2.0` (operator `v0.94.1`) | prometheus-community `Chart.yaml` | |
| nginx (Part 3 fix) | `1.25.5` | Docker Hub tags (1.25.2-1.25.5 exist; `1.25.99` does not) | |
| curlimages/curl (smoke job) | `8.7.1` | provided `smoke-job.yaml`; amd64+arm64 | |
| distroless base | `gcr.io/distroless/static:nonroot` | manifest: amd64+arm64 | UID 65532 |
| Go builder | `golang:1.25-alpine` | manifest: multi-arch | to be re-checked against latest Go at M2 |

Latest upstream at lookup time was newer for k3s/kubernetes (v1.37.1); v1.35.5 was chosen as the version k3d ships and tests against, with confirmed multi-arch images.
