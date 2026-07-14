# Juggler (github.com/juggler-ai/juggler) headless server + a full dev toolchain
# for the golem and k3s-lab repos, so the in-Juggler Claude Code agent can build,
# test, and PR them (and drive Docker via the pod's DinD sidecar).
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
# msitarzewski/agency-agents commit providing the 220+ agent definitions (same
# pin as apps/agent-os).
ARG AGENCY_AGENTS_REF=90ae2b27d159d9a4b80160484b0c00f67c7dd0ff
# k3s-lab CI parity (see .github/workflows/validate.yaml).
ARG KUSTOMIZE_VERSION=5.3.0
ARG KUBECONFORM_VERSION=0.6.7
ARG TERRAFORM_VERSION=1.9.8

# 1) Juggler runtime libraries (libgtk-4-1 libwebkitgtk-6.0-4 pull in libsoup,
#    libjavascriptcoregtk, glib, libX11, ...) + virtual display (xvfb) +
#    xdpyinfo (x11-utils, for the display-readiness probe in entrypoint.sh) +
#    software GL, tini as a PID 1 that reaps WebKit's child processes, plus the
#    shell/build tooling both repos need: make/build-essential (node-gyp, golem
#    Makefile), python3 + pytest + yamllint (golem tools, k3s-lab lint),
#    openssh-client (git push), jq, git, ripgrep.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git ripgrep procps tini less unzip \
      libgtk-4-1 libwebkitgtk-6.0-4 \
      xvfb x11-utils \
      libgl1-mesa-dri libegl-mesa0 fonts-liberation \
      build-essential make openssh-client jq \
      python3 python3-pip python3-venv python3-pytest yamllint age \
    && rm -rf /var/lib/apt/lists/*

# 2) Node.js 22 (NodeSource) + the Claude Code CLI that backs Juggler's
#    "claudecode" provider (same package + pin as apps/agent-os).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# 3) Docker CLI + buildx (client only — dockerd runs in the pod's privileged
#    DinD sidecar; the agent talks to it via DOCKER_HOST=tcp://localhost:2375).
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# 4) Playwright's Chromium OS dependencies (golem's some-hero e2e suite). We bake
#    only the OS libs here (needs root); golem's own `npx playwright install
#    chromium` downloads the version-matched browser at test time into the
#    PVC-backed cache. Run `playwright install chromium` WITHOUT --with-deps in
#    the pod (it's non-root; the deps are already present).
RUN npx --yes playwright install-deps chromium \
    && rm -rf /var/lib/apt/lists/* ~/.npm

# 5) k3s-lab GitOps toolbelt (pinned; kustomize/kubeconform match validate.yaml,
#    the rest track upstream stable). kubectl + flux + sops + terraform + gh.
RUN set -eux; \
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin kustomize; \
    curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
      | tar -xz -C /usr/local/bin kubeconform; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"; \
    chmod +x /usr/local/bin/kubectl; \
    SOPS_VER="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)"; \
    curl -fsSLo /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/${SOPS_VER}/sops-${SOPS_VER}.linux.amd64"; \
    chmod +x /usr/local/bin/sops; \
    FLUX_VER="$(curl -fsSL https://api.github.com/repos/fluxcd/flux2/releases/latest | jq -r .tag_name | sed 's/^v//')"; \
    curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VER}/flux_${FLUX_VER}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin flux; \
    GH_VER="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_amd64.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VER}_linux_amd64/bin/gh" /usr/local/bin/gh; \
    curl -fsSLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"; \
    unzip -o /tmp/tf.zip -d /usr/local/bin terraform; \
    rm -rf /tmp/gh_* /tmp/tf.zip; \
    kustomize version; kubeconform -v; kubectl version --client=true 2>/dev/null | head -1; \
    sops --version; flux --version; gh --version | head -1; terraform version | head -1

# 6) The Juggler server binary (checksum-verified official release asset). Only
#    the headless `juggler` member is installed; juggler-app is the GTK desktop
#    launcher and is not used here.
RUN cd /tmp \
    && curl -fsSLO "https://github.com/juggler-ai/juggler/releases/download/v${JUGGLER_VERSION}/juggler-linux-amd64.tar.gz" \
    && curl -fsSLO "https://github.com/juggler-ai/juggler/releases/download/v${JUGGLER_VERSION}/checksums.txt" \
    && grep 'juggler-linux-amd64.tar.gz$' checksums.txt | sha256sum -c - \
    && tar -xzf juggler-linux-amd64.tar.gz juggler \
    && install -m 0755 juggler /usr/local/bin/juggler \
    && rm -f juggler juggler-linux-amd64.tar.gz checksums.txt

# 7) The 220+ agency-agents definitions (baked; entrypoint copies them into the
#    PVC-backed ~/.claude/agents on each start, same as apps/agent-os).
RUN git clone https://github.com/msitarzewski/agency-agents /opt/agency-agents \
    && git -C /opt/agency-agents checkout "${AGENCY_AGENTS_REF}" \
    && rm -rf /opt/agency-agents/.git

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ubuntu:24.04 ships a default 'ubuntu' user at uid 1000; replace it with a
# named juggler user so tooling doing getpwuid(1000) resolves cleanly, and
# pre-create the PVC mountpoint.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash juggler \
    && mkdir -p /data && chown 1000:1000 /data

# HOME + JUGGLER_CONFIG_DIR live on the PVC mounted at /data so config,
# credentials, sessions, cloned repos, gh/ssh auth and the Playwright browser
# cache all survive restarts. PIP_BREAK_SYSTEM_PACKAGES lets the agent `pip
# install` ad hoc on this externally-managed Python (PEP 668).
ENV HOME=/data \
    JUGGLER_CONFIG_DIR=/data/.juggler \
    PIP_BREAK_SYSTEM_PACKAGES=1

USER 1000
WORKDIR /data
EXPOSE 3939
# tini reaps zombies (WebKit spawns WebProcess/NetworkProcess children) and
# forwards signals to the entrypoint, which execs juggler as tini's child.
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
