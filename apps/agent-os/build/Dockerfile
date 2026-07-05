# agent-os web UI + Claude Code harness.
# Built by .github/workflows/build-agent-os.yaml -> ghcr.io/tuckermclean/agent-os
FROM node:22-bookworm-slim

ARG AGENT_OS_REF=v0.2.1
ARG CLAUDE_CODE_VERSION=2.1.201
# msitarzewski/agency-agents commit providing the 232 agent definitions
ARG AGENCY_AGENTS_REF=90ae2b27d159d9a4b80160484b0c00f67c7dd0ff

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client procps python3 make g++ ripgrep tmux \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
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
    DB_PATH=/home/node/.agent-os/agent-os.db \
    DISABLE_AUTOUPDATER=1

USER node
WORKDIR /home/node
EXPOSE 3011
ENTRYPOINT ["/entrypoint.sh"]
