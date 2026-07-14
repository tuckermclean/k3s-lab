#!/usr/bin/env bash
# /data is a PVC (HOME + JUGGLER_CONFIG_DIR). Seed dirs, bring up a virtual
# display, then hand off to the server as the container's main process.
set -uo pipefail

mkdir -p "${JUGGLER_CONFIG_DIR:-/data/.juggler}" /data/projects "$HOME/.claude"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

# No accessibility bus in a container — silence the harmless GTK a11y warning.
export GTK_A11Y=none NO_AT_BRIDGE=1
# The engine WebView renders in software (no GPU), and WebKit's process sandbox
# needs unprivileged user namespaces that k3s pods don't grant — disable it.
# Safe: the engine only ever loads Juggler's own page over loopback.
export WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 \
       WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1

# Start our own X server and WAIT until it accepts connections before launching
# Juggler. We deliberately do NOT use `xvfb-run`: its fire-and-forget wrapper
#   (a) races the engine WebView against display readiness and its Xauthority
#       cookie at cold boot — the WebView then can't open the display and Juggler
#       exits ("Authorization required, but no authorization protocol specified"
#       / no output at all), leaving the server never bound; and
#   (b) wedges in sigsuspend when its child dies, so PID 1 never exits and k8s
#       can't restart the broken pod (it sits Ready 1/2 forever).
# Running Xvfb ourselves with NO auth cookie (the pod is an isolated network
# namespace, nothing else can reach :99) and then `exec`ing Juggler makes Juggler
# the container's main process: if it dies, the container dies and is restarted.
export DISPLAY=:99
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
XVFB_PID=$!
for _ in $(seq 1 50); do
  [ -S /tmp/.X11-unix/X99 ] && xdpyinfo -display :99 >/dev/null 2>&1 && break
  kill -0 "$XVFB_PID" 2>/dev/null || { echo "FATAL: Xvfb exited before becoming ready" >&2; exit 1; }
  sleep 0.2
done

# --kill-existing: on restart, take over a stale lock left by a prior instance on
# the PVC instead of prompting on a TTY that doesn't exist (which would hang).
# No --public needed: the in-pod nginx sidecar reaches the server over loopback
# (satisfies the LAN gate) and rewrites Host->localhost (satisfies the /api gate);
# all real access control is the authentik forwardAuth middleware (ingressroute.yaml).
exec juggler --port 3939 --project /data/projects --kill-existing
