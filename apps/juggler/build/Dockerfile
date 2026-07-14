# Juggler (github.com/juggler-ai/juggler) headless server + Claude Code CLI.
# Upstream ships no container image; this wraps the official prebuilt
# juggler-linux-amd64 release binary. Built by
# .github/workflows/build-juggler.yaml -> ghcr.io/tuckermclean/juggler
#
# The Linux "headless" server is NOT truly headless: cmd/juggler unconditionally
# spawns a hidden WebKitGTK/Wails WebView (the "engine") that is the only thing
# that executes tools, and it self-terminates if no display is present. So the
# image ships GTK4 + WebKitGTK 6.0 (the exact runtime deps named in the release
# README.txt), a virtual X display (Xvfb) and software GL. Base pinned to
# ubuntu:24.04: the release binary links libwebkitgtk-6.0.so.4 / libgtk-4.so.1
# and needs glibc >= 2.34 (README: "Ubuntu 24.04+"); Debian bookworm-slim does
# not ship libwebkitgtk-6.0-4.
FROM ubuntu:24.04

ARG JUGGLER_VERSION=0.3.7
ARG CLAUDE_CODE_VERSION=2.1.201

# 1) Juggler runtime libraries (libgtk-4-1 libwebkitgtk-6.0-4 pull in libsoup,
#    libjavascriptcoregtk, glib, libX11, ...) + virtual display (xvfb) +
#    xdpyinfo (x11-utils, for the display-readiness probe in entrypoint.sh) +
#    software GL, tini as a PID 1 that reaps WebKit's child processes and
#    forwards signals, then the agent's own shell tooling and TLS/download prereqs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep procps tini \
      libgtk-4-1 libwebkitgtk-6.0-4 \
      xvfb x11-utils \
      libgl1-mesa-dri libegl-mesa0 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# 2) Node.js 22 (NodeSource) for the Claude Code CLI that backs Juggler's
#    "claudecode" provider (same package + pin approach as apps/agent-os).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# 3) The Juggler server binary (checksum-verified official release asset). Only
#    the headless `juggler` member is installed; juggler-app is the GTK desktop
#    launcher and is not used here.
RUN cd /tmp \
    && curl -fsSLO "https://github.com/juggler-ai/juggler/releases/download/v${JUGGLER_VERSION}/juggler-linux-amd64.tar.gz" \
    && curl -fsSLO "https://github.com/juggler-ai/juggler/releases/download/v${JUGGLER_VERSION}/checksums.txt" \
    && grep 'juggler-linux-amd64.tar.gz$' checksums.txt | sha256sum -c - \
    && tar -xzf juggler-linux-amd64.tar.gz juggler \
    && install -m 0755 juggler /usr/local/bin/juggler \
    && rm -f juggler juggler-linux-amd64.tar.gz checksums.txt

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ubuntu:24.04 ships a default 'ubuntu' user at uid 1000; replace it with a
# named juggler user so tooling doing getpwuid(1000) resolves cleanly, and
# pre-create the PVC mountpoint.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash juggler \
    && mkdir -p /data && chown 1000:1000 /data

# HOME + JUGGLER_CONFIG_DIR both live on the PVC mounted at /data so config,
# credentials and sessions survive restarts.
ENV HOME=/data \
    JUGGLER_CONFIG_DIR=/data/.juggler

USER 1000
WORKDIR /data
EXPOSE 3939
# tini reaps zombies (WebKit spawns WebProcess/NetworkProcess children) and
# forwards signals to the entrypoint, which execs juggler as tini's child.
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
