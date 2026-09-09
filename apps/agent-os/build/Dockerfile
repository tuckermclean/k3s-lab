# agent-os web UI + Claude Code harness.
# Built by .github/workflows/build-agent-os.yaml -> ghcr.io/tuckermclean/agent-os
FROM node:24-bookworm-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e

# BuildKit-provided; differ only when cross-building (e.g. the arm64 leg of
# a linux/amd64,linux/arm64 buildx build running under QEMU on an amd64
# builder). Used below to skip executing target-arch binaries as
# smoke-tests under emulation, while still verifying their SHA and chmod
# unconditionally.
ARG BUILDARCH
ARG TARGETARCH

ARG AGENT_OS_REF=v0.2.1
# Seed version installed by entrypoint.sh via the native installer at first
# boot; Claude Code then self-updates in place on the PVC-backed ~/.local.
ARG CLAUDE_CODE_VERSION=2.1.245
# msitarzewski/agency-agents commit providing the 220+ agent definitions
ARG AGENCY_AGENTS_REF=c89557f78509868c6d4cc08e5cbc79bc8625fe1c
# Seed version installed by entrypoint.sh via the official standalone installer
# at first boot; Codex then self-updates in place on the PVC-backed ~/.local.
ARG CODEX_VERSION=0.149.1

# jq/unzip/python3-pexpect: SBOM validation + the boot-test harness (pexpect).
# qemu-system-x86 provides both qemu-system-x86_64 and qemu-system-i386
# (the latter is a virtual package on Debian, resolved to the same real
# package) for ISO boot tests — TCG software emulation only in-pod (no
# /dev/kvm, no nested virt), which is expected; boot tests just run slower.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client procps python3 make g++ ripgrep tmux less vim nano age \
      jq unzip python3-pexpect qemu-system-x86 \
      libicu72 \
    && rm -rf /var/lib/apt/lists/*

# sops (SOPS secret encryption) — not packaged in Debian, so fetch the release
# binary and verify its checksum. Pairs with `age` (installed above), the
# backend this repo's *.sops.yaml files are encrypted to.
ARG SOPS_VERSION=3.13.3
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b" ;; \
      arm64) sha="53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}"; \
    echo "${sha}  /usr/local/bin/sops" | sha256sum -c -; \
    chmod +x /usr/local/bin/sops; \
    if [ "$BUILDARCH" = "$TARGETARCH" ]; then sops --version; else echo "skip sops smoke-test under emulation ($BUILDARCH->$TARGETARCH)"; fi

# Docker CLI + buildx (client only) — dockerd runs in the pod's privileged
# DinD sidecar (see apps/agent-os/deployment.yaml); the agent talks to it via
# DOCKER_HOST=tcp://localhost:2375. Mirrors apps/juggler/build/Dockerfile's
# approach, except the apt repo line is arch-aware
# ([arch=$(dpkg --print-architecture)]): juggler is an amd64-only image and
# hardcodes [arch=amd64], which would break the arm64 leg of this multi-arch
# build.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# CVE scanners (grype, trivy, osv-scanner) for the ISO build+scan pipeline.
# Release binaries, checksum-verified against each project's published
# checksums file.
ARG GRYPE_VERSION=0.116.1
ARG TRIVY_VERSION=0.72.0
ARG OSV_SCANNER_VERSION=2.4.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) \
        grype_sha="0122df7b655981abe547ad3d2190d65551dac6a2bfc80b4dc2a989b5d0587458"; \
        trivy_asset="Linux-64bit"; \
        trivy_sha="bbb64b9695866ce4a7a8f5c9592002c5961cab378577fa3f8a040df362b9b2ea"; \
        osv_sha="15314940c10d26af9c6649f150b8a47c1262e8fc7e17b1d1029b0e479e8ed8a0"; \
        ;; \
      arm64) \
        grype_sha="a8d7504a149629324eb5f4ce3dc25dfd211bbfe047e64ee2bf7844b466c3d84d"; \
        trivy_asset="Linux-ARM64"; \
        trivy_sha="2ca2c023109c2db6b2b77366b6717291452d4531167377d95c79547f0c8e3467"; \
        osv_sha="44e580752910f0ff36ec99aff59af20f65df1e859aa31e5605a8f0d055b496e9"; \
        ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/grype.tar.gz \
      "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_${arch}.tar.gz"; \
    echo "${grype_sha}  /tmp/grype.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/grype.tar.gz -C /usr/local/bin grype; \
    curl -fsSL -o /tmp/trivy.tar.gz \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${trivy_asset}.tar.gz"; \
    echo "${trivy_sha}  /tmp/trivy.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy; \
    curl -fsSL -o /usr/local/bin/osv-scanner \
      "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_${arch}"; \
    echo "${osv_sha}  /usr/local/bin/osv-scanner" | sha256sum -c -; \
    chmod +x /usr/local/bin/osv-scanner; \
    rm -f /tmp/grype.tar.gz /tmp/trivy.tar.gz; \
    if [ "$BUILDARCH" = "$TARGETARCH" ]; then grype version; trivy --version; osv-scanner --version; else echo "skip grype/trivy/osv-scanner smoke-test under emulation ($BUILDARCH->$TARGETARCH)"; fi

# cyclonedx-cli — SBOM schema validation. Release binaries; upstream ships no
# checksums file for this project, so the hash below is pinned against the
# exact asset fetched for this ARG version (computed and verified at the time
# this Dockerfile was written) instead of a published checksums list.
ARG CYCLONEDX_CLI_VERSION=0.33.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) \
        cdx_asset="cyclonedx-linux-x64"; \
        cdx_sha="bfc8b2538da86fe239bc53658bbb63c1c8c510a293c1e6891aa5bea5d3c58746"; \
        ;; \
      arm64) \
        cdx_asset="cyclonedx-linux-arm64"; \
        cdx_sha="b2e9fdf9665ef49868a2ec012171c6e785dcd69745bc5869e53e4f4bfb096a5f"; \
        ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/cyclonedx \
      "https://github.com/CycloneDX/cyclonedx-cli/releases/download/v${CYCLONEDX_CLI_VERSION}/${cdx_asset}"; \
    echo "${cdx_sha}  /usr/local/bin/cyclonedx" | sha256sum -c -; \
    chmod +x /usr/local/bin/cyclonedx; \
    if [ "$BUILDARCH" = "$TARGETARCH" ]; then cyclonedx --version; else echo "skip cyclonedx smoke-test under emulation ($BUILDARCH->$TARGETARCH)"; fi

# AWS CLI v2 — publishes the ISO build dashboard/SBOM to S3. Same as
# cyclonedx-cli above: no published checksums file for the installer zip, so
# the hash is pinned against the exact asset fetched for this ARG version.
ARG AWS_CLI_VERSION=2.36.14
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) aws_asset="x86_64"; aws_sha="43b34875482244039716cc3725d1f60e7d47ef3cfb2a19e114759a46db24dc30" ;; \
      arm64) aws_asset="aarch64"; aws_sha="61e2fb72b36dc0ad98912b3a7b7469c886b90ea703f1096428a152ab09babd8a" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/awscliv2.zip \
      "https://awscli.amazonaws.com/awscli-exe-linux-${aws_asset}-${AWS_CLI_VERSION}.zip"; \
    echo "${aws_sha}  /tmp/awscliv2.zip" | sha256sum -c -; \
    unzip -q /tmp/awscliv2.zip -d /tmp/awscli-install; \
    /tmp/awscli-install/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/awscli-install; \
    if [ "$BUILDARCH" = "$TARGETARCH" ]; then aws --version; else echo "skip aws smoke-test under emulation ($BUILDARCH->$TARGETARCH)"; fi

# GitHub CLI (gh) — lets the agent open PRs and talk to GitHub from inside the
# container. Release binary, checksum-verified against the published
# gh_<ver>_checksums.txt (same pattern as sops/grype/trivy above). gh is a plain
# tool, not an account-versioned self-updating CLI like claude/codex, so it lives
# root-owned in /usr/local/bin rather than the PVC-backed ~/.local.
ARG GH_VERSION=2.98.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="3b8ac6b30336802fc1a858d7c084e11cdf24ac1a761ca90b68022d7d729208de" ;; \
      arm64) sha="cf689084f3a3618f7eae4a2420d335d74626d65f5e594b9828d125d69f800d86" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz"; \
    echo "${sha}  /tmp/gh.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tar.gz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${arch}"; \
    if [ "$BUILDARCH" = "$TARGETARCH" ]; then gh --version; else echo "skip gh smoke-test under emulation ($BUILDARCH->$TARGETARCH)"; fi

# Claude Code is intentionally NOT installed at build time: entrypoint.sh
# seeds it via the native installer into the PVC-backed ~/.local at first
# boot (see CLAUDE_CODE_VERSION above), so it can self-update in place as
# the non-root node user.

# Codex CLI is intentionally NOT installed at build time either: entrypoint.sh
# installs the standalone native binary via the official installer into the
# PVC-backed ~/.local at first boot (see CODEX_VERSION above), so the non-root
# node user can self-update it in place (`codex update` / startup self-update),
# exactly like Claude Code. A build-time `npm i -g` is root-owned and
# un-updatable, and /home/node is a PVC that masks anything baked into it.

# Bake the app itself: the npm package's `agent-os` bin is an installer that
# clones into $HOME at runtime; we want an immutable, prebuilt copy instead.
RUN git clone --branch "${AGENT_OS_REF}" --depth 1 https://github.com/saadnvd1/agent-os /opt/agent-os \
    && cd /opt/agent-os \
    && npm ci --legacy-peer-deps \
    && npx next build \
    && npm cache clean --force \
    && chown -R node:node /opt/agent-os

RUN git clone https://github.com/msitarzewski/agency-agents /opt/agency-agents \
    && git -C /opt/agency-agents checkout "${AGENCY_AGENTS_REF}" \
    && rm -rf /opt/agency-agents/.git

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PORT=3011 \
    DB_PATH=/home/node/.agent-os/agent-os.db
# First-boot seed version only: entrypoint.sh installs this via the native
# installer if ~/.local/bin/claude is missing, then Claude Code self-updates
# from there, so bumping this ARG/ENV only matters for fresh PVCs.
ENV CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}
# First-boot seed version only (same idea as CLAUDE_CODE_VERSION): entrypoint.sh
# installs this via the standalone installer if ~/.local/bin/codex is missing,
# then Codex self-updates from there, so bumping this only matters for fresh PVCs.
ENV CODEX_VERSION=${CODEX_VERSION}
# Native-installer location for Claude Code (installed at first boot by
# entrypoint.sh into the PVC-backed home dir).
ENV PATH="/home/node/.local/bin:${PATH}"

USER node
WORKDIR /home/node
EXPOSE 3011
ENTRYPOINT ["/entrypoint.sh"]
