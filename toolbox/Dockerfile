# Toolbox: everything the scripts need, so the reviewer installs nothing on the host.
# Versions are pinned (see VERSIONS.md). TARGETARCH is amd64 or arm64 (BuildKit sets it).
FROM debian:bookworm-slim

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.35.5
ARG HELM_VERSION=v4.3.0
ARG TERRAFORM_VERSION=1.16.5
ARG K6_VERSION=v2.3.0
ARG K3D_VERSION=v5.9.0
ARG DOCKER_VERSION=29.6.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq unzip tar gzip gettext-base \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in amd64) DARCH=x86_64 ;; arm64) DARCH=aarch64 ;; *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; esac; \
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm"; \
    curl -fsSL -o /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"; \
    unzip -q /tmp/tf.zip terraform -d /usr/local/bin; rm /tmp/tf.zip; \
    curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "k6-${K6_VERSION}-linux-${TARGETARCH}/k6"; \
    curl -fsSL -o /usr/local/bin/k3d "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${TARGETARCH}"; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${DARCH}/docker-${DOCKER_VERSION}.tgz" | tar -xz -C /usr/local/bin --strip-components=1 docker/docker; \
    chmod +x /usr/local/bin/*

# Scripts run in /workspace (the repo bind-mount); git must trust the mounted .git owner.
RUN git config --system --add safe.directory /workspace

WORKDIR /workspace
CMD ["sleep", "infinity"]
