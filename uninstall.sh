#!/bin/bash
# Removes the notify.sh hook entries from the Claude Code and Codex configs (with a
# backup of each file that changes) and deletes the installed scripts. Other hooks and
# settings are left alone, as is terminal-notifier.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/envelope/hooks"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
source "$REPO/scripts/config.sh"

envelope_config remove "$HOME/.claude/settings.json" claude
envelope_config remove "${CODEX_HOME:-$HOME/.codex}/hooks.json" codex

for f in notify.sh focus-host.sh focus-terminal.sh claude-icon.png chatgpt-icon.png; do
  rm -f "$HOOKS_DIR/$f"
  rm -f "$HOME/.claude/hooks/$f"
done
echo "==> Removed hook scripts from $HOOKS_DIR"
