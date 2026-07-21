# agent-os web UI + Claude Code harness.
# Built by .github/workflows/build-agent-os.yaml -> ghcr.io/tuckermclean/agent-os
FROM node:24-bookworm-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d

ARG AGENT_OS_REF=v0.2.1
ARG CLAUDE_CODE_VERSION=2.1.201
# msitarzewski/agency-agents commit providing the 220+ agent definitions
ARG AGENCY_AGENTS_REF=90ae2b27d159d9a4b80160484b0c00f67c7dd0ff

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client procps python3 make g++ ripgrep tmux less vim nano age \
    && rm -rf /var/lib/apt/lists/*

# sops (SOPS secret encryption) — not packaged in Debian, so fetch the release
# binary and verify its checksum. Pairs with `age` (installed above), the
# backend this repo's *.sops.yaml files are encrypted to.
ARG SOPS_VERSION=3.13.2
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="154dfe4cd70554bdd82b98e4cd4acf191d43d01ead6f00a73477aa44c4ac42ef" ;; \
      arm64) sha="78abf2e15c86250a1553ae6f53aba96be6b2a8126f160b1534959add3467ad76" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}"; \
    echo "${sha}  /usr/local/bin/sops" | sha256sum -c -; \
    chmod +x /usr/local/bin/sops; \
    sops --version

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# Install Codex CLI globally
RUN npm install -g @openai/codex

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
    DB_PATH=/home/node/.agent-os/agent-os.db \
    DISABLE_AUTOUPDATER=1

USER node
WORKDIR /home/node
EXPOSE 3011
ENTRYPOINT ["/entrypoint.sh"]
