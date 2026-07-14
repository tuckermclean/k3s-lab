#!/usr/bin/env bash
# /data is a PVC (HOME + JUGGLER_CONFIG_DIR). Seed dirs idempotently, then start
# the headless server under a virtual display.
set -uo pipefail

mkdir -p "${JUGGLER_CONFIG_DIR:-/data/.juggler}" /data/projects "$HOME/.claude"

# A writable XDG runtime dir for the GTK/D-Bus session the engine WebView needs.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

# The engine WebView must render in software (no GPU), and WebKit's process
# sandbox needs unprivileged user namespaces that k3s pods don't grant — disable
# it. Safe here: the engine only ever loads Juggler's own page over loopback,
# never untrusted web content (same rationale as Juggler's own CI).
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE=1

# No --public: the in-pod nginx sidecar reaches the server over loopback, which
# satisfies Juggler's LAN gate, and it rewrites Host->localhost so the
# DNS-rebinding /api gate passes too. All real access control is the authentik
# forwardAuth middleware in front of the Service (see ingressroute.yaml).
exec xvfb-run -a --server-args='-screen 0 1920x1080x24' \
  dbus-run-session -- \
  juggler --port 3939 --project /data/projects
