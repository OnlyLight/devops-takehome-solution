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
| descheduler chart | `0.37.0` (app `0.37.0`) | `helm search repo descheduler/descheduler --versions` | restores the spot/on-demand spread after HPA scale-down; default policy narrowed to one plugin (see `descheduler/values.yaml`) |
| nginx (Part 3 fix) | `1.25.5` | Docker Hub tags (1.25.2-1.25.5 exist; `1.25.99` does not) | |
| curlimages/curl (smoke job) | `8.7.1` | provided `smoke-job.yaml`; amd64+arm64 | |
| distroless base | `gcr.io/distroless/static:nonroot` | manifest: amd64+arm64 | UID 65532 |
| Go builder | `golang:1.27-alpine` (go1.27.2) | manifest: multi-arch; latest per go.dev | checked at M2; local tests ran on go1.27.1 |

Latest upstream at lookup time was newer for k3s/kubernetes (v1.37.1); v1.35.5 was chosen as the version k3d ships and tests against, with confirmed multi-arch images.

## GitHub Actions (pinned by commit SHA, resolved via the GitHub API on 2026-10-10)
| Action | Tag | Commit |
|---|---|---|
| actions/checkout | v7.0.1 | 3d3c42e5aac5ba805825da76410c181273ba90b1 |
| actions/setup-go | v7.0.0 | b7ad1dad31e06c5925ef5d2fc7ad053ef454303e |
| docker/setup-buildx-action | v4.4.1 | f87e5991a6d7451dcb8d9637bfbc97413f497069 |
| docker/login-action | v4.6.0 | dbcb813823bdd20940b903addbd779551569679f |
| docker/metadata-action | v6.2.0 | dc802804100637a589fabce1cb79ff13a1411302 |
| docker/build-push-action | v7.4.0 | c3c9e263c25d99ce0380d002d59b67737d91b0dc |
