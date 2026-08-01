# agent-os web UI + Claude Code harness.
# Built by .github/workflows/build-agent-os.yaml -> ghcr.io/tuckermclean/agent-os
FROM node:24-bookworm-slim@sha256:235600a8101ab264e117b1768e925532262668dc9b581ef1dd7d96ced463b8e7

ARG AGENT_OS_REF=v0.2.1
# Seed version installed by entrypoint.sh via the native installer at first
# boot; Claude Code then self-updates in place on the PVC-backed ~/.local.
ARG CLAUDE_CODE_VERSION=2.1.220
# msitarzewski/agency-agents commit providing the 220+ agent definitions
ARG AGENCY_AGENTS_REF=c89557f78509868c6d4cc08e5cbc79bc8625fe1c

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client procps python3 make g++ ripgrep tmux less vim nano age \
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
    sops --version

# Claude Code is intentionally NOT installed at build time: entrypoint.sh
# seeds it via the native installer into the PVC-backed ~/.local at first
# boot (see CLAUDE_CODE_VERSION above), so it can self-update in place as
# the non-root node user.

# Install Codex CLI globally
RUN npm install -g @openai/codex@0.146.0 \
    && npm cache clean --force

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
# Native-installer location for Claude Code (installed at first boot by
# entrypoint.sh into the PVC-backed home dir).
ENV PATH="/home/node/.local/bin:${PATH}"

USER node
WORKDIR /home/node
EXPOSE 3011
ENTRYPOINT ["/entrypoint.sh"]
