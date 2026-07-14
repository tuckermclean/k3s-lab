#!/usr/bin/env bash
# /data is a PVC (HOME + JUGGLER_CONFIG_DIR). Seed dirs + the Claude Code harness
# idempotently, bring up a virtual display, then hand off to the server as the
# container's main process.
set -uo pipefail

mkdir -p "${JUGGLER_CONFIG_DIR:-/data/.juggler}" /data/projects \
         "$HOME/.claude/agents" "$HOME/.ssh"
chmod 700 "$HOME/.ssh" 2>/dev/null || true

# Let git operate on repos cloned into /data regardless of uid ownership quirks.
git config --global --add safe.directory '*' 2>/dev/null || true

# ── Claude Code harness (same seeding as apps/agent-os) ──────────────────────
# agency-agents division dirs -> flat ~/.claude/agents/ (non-agent dirs skipped).
for dir in /opt/agency-agents/*/; do
  case "$(basename "$dir")" in
    examples|integrations|scripts|docs) continue ;;
  esac
  cp -f "$dir"*.md "$HOME/.claude/agents/" 2>/dev/null || true
done

# superpowers plugin installs into the PVC-backed ~/.claude; skip if already there.
if ! claude plugin list 2>/dev/null | grep -qi superpowers; then
  claude plugin marketplace add anthropics/claude-plugins-official \
    || echo "WARN: official marketplace add failed (may already be registered)" >&2
  claude plugin install superpowers@claude-plugins-official \
    || echo "WARN: superpowers plugin install failed; run 'claude plugin install superpowers@claude-plugins-official' manually" >&2
fi

# Apply the Claude Code env (OAuth token + subagent model) to every session
# regardless of how juggler spawns the CLI.
node -e '
const fs = require("fs");
const p = process.env.HOME + "/.claude/settings.json";
let s = {}; try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
s.env = { ...s.env,
  CLAUDE_CODE_OAUTH_TOKEN: process.env.CLAUDE_CODE_OAUTH_TOKEN || "",
  CLAUDE_CODE_SUBAGENT_MODEL: process.env.CLAUDE_CODE_SUBAGENT_MODEL || "" };
fs.writeFileSync(p, JSON.stringify(s, null, 2));
' || echo "WARN: failed to write ~/.claude/settings.json env block" >&2

# Global working agreement: use superpowers proactively. Create-if-absent so we
# never clobber the user's own edits.
if [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
  cat > "$HOME/.claude/CLAUDE.md" <<'EOF'
# Working agreement

You have the **superpowers** plugin installed. Use it proactively and as often as
possible: before any non-trivial task, check for a relevant skill and invoke it —
brainstorming before building a feature, systematic-debugging before fixing a bug,
test-driven-development when implementing, requesting-code-review before merging,
and so on. If a skill plausibly applies, use it rather than improvising.

The 220+ agency agents in ~/.claude/agents/ are available via the Agent tool —
delegate specialized work to them.

Docker is available (DOCKER_HOST points at the pod's DinD sidecar): feel free to
spin up throwaway containers for tests.
EOF
fi

# ── Virtual display + server ─────────────────────────────────────────────────
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
