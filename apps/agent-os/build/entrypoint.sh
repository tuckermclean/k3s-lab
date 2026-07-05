#!/usr/bin/env bash
# /home/node is a PVC: seed the Claude Code harness on every start, idempotently.
set -uo pipefail

mkdir -p "$HOME/.claude/agents" "$HOME/.agent-os" "$HOME/workspace"

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
export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
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
  CLAUDE_CODE_OAUTH_TOKEN: process.env.CLAUDE_CODE_OAUTH_TOKEN || "",
  CLAUDE_CODE_SUBAGENT_MODEL: process.env.CLAUDE_CODE_SUBAGENT_MODEL || "" };
fs.writeFileSync(p, JSON.stringify(s, null, 2));
' || echo "WARN: failed to write ~/.claude/settings.json env block" >&2

cd /opt/agent-os
exec npm start
