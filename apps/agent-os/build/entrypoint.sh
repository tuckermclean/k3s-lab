#!/usr/bin/env bash
# /home/node is a PVC: seed the Claude Code harness on every start, idempotently.
set -uo pipefail

mkdir -p "$HOME/.claude/agents" "$HOME/.agent-os" "$HOME/workspace" "$HOME/.local/bin"

# Claude Code isn't baked into the image: install it via the native installer
# on first boot, straight into the PVC-backed ~/.local. This lets the
# non-root node user self-update Claude Code in place (a build-time npm
# install would be root-owned and un-updatable by the running user).
if [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION:-2.1.220}" \
    || echo "WARN: claude native install failed" >&2
fi
export PATH="$HOME/.local/bin:$PATH"

# Codex CLI isn't baked into the image either: install the standalone native
# binary via the official installer into the PVC-backed ~/.local on first boot,
# so the non-root node user can self-update it in place (`codex update` /
# startup self-update). A build-time `npm i -g` would be root-owned and
# un-updatable, and /home/node is a PVC so anything baked into it at build time
# is masked by the mount anyway. Mirrors the Claude Code install above.
if [ ! -x "$HOME/.local/bin/codex" ]; then
  curl -fsSL https://chatgpt.com/codex/install.sh \
    | CODEX_RELEASE="${CODEX_VERSION:-0.149.1}" CODEX_NON_INTERACTIVE=1 sh \
    || echo "WARN: codex standalone install failed" >&2
fi

# agency-agents division dirs -> flat ~/.claude/agents/ (non-agent dirs skipped)
for dir in /opt/agency-agents/*/; do
  case "$(basename "$dir")" in
    examples|integrations|scripts|docs) continue ;;
  esac
  cp -f "$dir"*.md "$HOME/.claude/agents/" 2>/dev/null || true
done

# superpowers plugin installs into PVC-backed ~/.claude; skip if already there
if ! claude plugin list 2>/dev/null | grep -qi superpowers; then
  claude plugin marketplace add anthropics/claude-plugins-official \
    || echo "WARN: official marketplace add failed (may already be registered)" >&2
  claude plugin install superpowers@claude-plugins-official \
    || echo "WARN: superpowers plugin install failed; run 'claude plugin install superpowers@claude-plugins-official' manually" >&2
fi

# agent-os spawns UI terminals with a hardcoded minimal env (server.ts) that
# drops the container's vars. Re-expose the harness vars two ways:
#  - ~/.bashrc block: interactive terminal shells (and anything launched from
#    them, incl. `claude`) pick them up
#  - ~/.claude/settings.json env block: Claude Code applies these to every
#    session regardless of how it was spawned (covers tmux agent sessions)
cat > "$HOME/.bashrc.agent-os" <<EOF
export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-}"
EOF
chmod 600 "$HOME/.bashrc.agent-os"
grep -q 'bashrc.agent-os' "$HOME/.bashrc" 2>/dev/null \
  || echo '[ -f ~/.bashrc.agent-os ] && . ~/.bashrc.agent-os' >> "$HOME/.bashrc"

node -e '
const fs = require("fs");
const p = process.env.HOME + "/.claude/settings.json";
let s = {}; try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
s.env = { ...s.env,
  CLAUDE_CODE_SUBAGENT_MODEL: process.env.CLAUDE_CODE_SUBAGENT_MODEL || "" };
// Full-scope login mode: no CLAUDE_CODE_OAUTH_TOKEN is set anywhere in this
// container (a long-lived setup-token overrides the interactive full-scope
// login and breaks Remote Control), so enable Remote Control at startup here
// instead. Run `claude-login` (or `claude auth login`) once interactively;
// credentials persist on the PVC (~/.claude/.credentials.json + ~/.claude.json).
s.remoteControlAtStartup = true;
fs.writeFileSync(p, JSON.stringify(s, null, 2));
' || echo "WARN: failed to write ~/.claude/settings.json env block" >&2

# Convenience wrapper for the phone workflow: `claude-login` runs the
# interactive login flow, extracts the auth URL, prints/hyperlinks it, and
# (if NTFY_URL is set) pushes it to a phone via ntfy so the operator can open
# it without a keyboard. It then forwards the code typed back in to the
# still-running `claude auth login` process so login completes normally.
cat > "$HOME/.local/bin/claude-login" <<'HELPER'
#!/usr/bin/env bash
# Convenience wrapper for the phone-only login workflow: runs `claude auth
# login` with its stdout piped through this script, extracts the first
# https:// URL it prints, surfaces that URL (marker line + OSC 8 hyperlink,
# and via ntfy if NTFY_URL is set) so it can be opened from a phone, then
# forwards whatever the operator types back in (the confirmation code) into
# the still-running `claude auth login` process so login completes normally.
# Not required to log in -- `claude auth login` on its own works fine -- this
# just smooths the case where the only device handy is a phone.
set -uo pipefail

# coproc gives us a bidirectional pipe pair to the child: CLAUDE_LOGIN[0] is
# its stdout (read end), CLAUDE_LOGIN[1] is its stdin (write end).
coproc CLAUDE_LOGIN { claude auth login 2>&1; }

# Background reader: stream the child's output to our stdout as-is, and
# on the first line containing a URL, print the marker + hyperlink + ntfy
# push. Runs concurrently with the foreground loop below so we can keep
# relaying output while waiting for (and forwarding) operator input.
(
  url_found=0
  while IFS= read -r line <&"${CLAUDE_LOGIN[0]}"; do
    printf '%s\n' "$line"
    if [ "$url_found" -eq 0 ] && [[ "$line" =~ (https://[^[:space:]]+) ]]; then
      url_found=1
      url="${BASH_REMATCH[1]}"
      printf 'CLAUDE-LOGIN-URL: %s\n' "$url"
      # OSC 8 hyperlink escape, so terminals that support it render this as
      # a clickable link too.
      printf '\e]8;;%s\e\\%s\e]8;;\e\\\n' "$url" "$url"
      if [ -n "${NTFY_URL:-}" ]; then
        curl -s -d "$url" "$NTFY_URL" >/dev/null 2>&1 \
          || printf 'WARN: failed to push login URL to NTFY_URL\n' >&2
      fi
    fi
  done
) &
reader_pid=$!

# Foreground: relay whatever the operator types (the confirmation code)
# straight into the child's stdin, until the child process exits.
while IFS= read -r input; do
  kill -0 "$CLAUDE_LOGIN_PID" 2>/dev/null || break
  printf '%s\n' "$input" >&"${CLAUDE_LOGIN[1]}" 2>/dev/null || break
done

wait "$reader_pid" 2>/dev/null || true
wait "$CLAUDE_LOGIN_PID" 2>/dev/null
HELPER
chmod +x "$HOME/.local/bin/claude-login"

cd /opt/agent-os
exec npm start
