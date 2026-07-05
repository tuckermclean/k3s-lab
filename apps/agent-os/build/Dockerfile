# agent-os web UI + Claude Code harness.
# Built by .github/workflows/build-agent-os.yaml -> ghcr.io/tuckermclean/agent-os
FROM node:22-bookworm-slim

ARG AGENT_OS_REF=v0.2.1
ARG CLAUDE_CODE_VERSION=2.1.201
# msitarzewski/agency-agents commit providing the 220+ agent definitions
ARG AGENCY_AGENTS_REF=90ae2b27d159d9a4b80160484b0c00f67c7dd0ff
ARG KUBECTL_VERSION=v1.36.2
ARG GH_VERSION=2.96.0

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client procps python3 make g++ ripgrep tmux less vim nano \
    && rm -rf /var/lib/apt/lists/*

# kubectl + GitHub CLI (static release binaries, no extra apt repos)
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
       | tar -xz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh \
    && rm -rf "/tmp/gh_${GH_VERSION}_linux_${arch}"

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
