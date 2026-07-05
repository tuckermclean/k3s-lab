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

cd /opt/agent-os
exec npm start
