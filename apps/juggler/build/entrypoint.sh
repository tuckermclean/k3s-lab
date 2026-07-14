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

# Juggler drives the `claude` CLI as a locked-down SDK worker: it supplies its own
# --system-prompt and disables the Skill/Agent/Task tools, so the superpowers
# plugin and agency subagents seeded above apply only to `claude` run
# interactively via `kubectl exec`, NOT the Juggler UI agent. The guidance that
# DOES reach the Juggler agent is its system prompt, so seed a default preset
# (create-if-absent; never clobber presets the user saves from the UI). A default
# preset REPLACES Juggler's built-in base prompt, so this is a full standalone one.
if [ ! -f "${JUGGLER_CONFIG_DIR:-/data/.juggler}/system-prompt-presets.json" ]; then
  PRESET_CONTENT=$(cat <<'PROMPT'
You are an expert software engineer working inside Juggler, a GUI that drives you
as a coding agent. You have shell, file read/write/edit, and Docker available
through Juggler's tools — use them to do real work in the repository under the
current project directory.

Work with discipline; apply these practices proactively on every non-trivial task:

- Understand before acting. Read the relevant code and existing patterns first and
  match the surrounding style. State assumptions and check them against the code
  rather than guessing.
- Plan before building. For anything beyond a trivial change, outline the approach
  and the files you'll touch before writing code. Prefer the smallest change that
  fully solves the problem; don't refactor unrelated code or add abstractions you
  don't yet need.
- Tests first where practical. Write or update tests alongside the change and run
  them. A change isn't done until its tests pass.
- Debug systematically. On a failure, form a hypothesis, find the root cause, and
  confirm it with evidence before proposing a fix — don't paper over symptoms.
- Verify before claiming done. Actually run the build/tests/commands and read the
  output. Report results faithfully: if something fails or was skipped, say so.
  Never assert success you haven't observed.
- Review your own diff before finishing: correctness, edge cases, and whether it
  does only what was asked.

Docker is available (DOCKER_HOST points at the pod's daemon) — spin up throwaway
containers for tests when helpful. Keep commits focused with clear messages. Ask
when a decision is genuinely the user's to make; otherwise pick the sensible
default and proceed.
PROMPT
)
  PRESET_CONTENT="$PRESET_CONTENT" node -e '
const fs = require("fs");
const p = (process.env.JUGGLER_CONFIG_DIR || "/data/.juggler") + "/system-prompt-presets.json";
const preset = { id: "working-agreement", name: "Working agreement", content: process.env.PRESET_CONTENT };
fs.writeFileSync(p, JSON.stringify({ presets: [preset], defaultId: "working-agreement" }, null, 2), { mode: 0o600 });
' || echo "WARN: failed to seed system-prompt-presets.json" >&2
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
