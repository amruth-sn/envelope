#!/bin/bash
# Removes the notify.sh hook entries from the Claude Code and Codex configs (with a
# backup of each file that changes) and deletes the installed scripts. Other hooks and
# settings are left alone, as is terminal-notifier.

set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
STAMP="$(date +%Y%m%d-%H%M%S)"

# strip_hook <file> <command>
strip_hook() {
  local file="$1" cmd="$2" tmp
  [ -s "$file" ] || return 0
  tmp="$(mktemp)"
  jq --arg cmd "$cmd" '
    if .hooks then
      .hooks |= (with_entries(
        .value |= (map(.hooks |= map(select(.command != $cmd))) | map(select((.hooks | length) > 0)))
      ) | with_entries(select((.value | length) > 0)))
    else . end
  ' "$file" > "$tmp"
  # Compare content, not bytes, so a file is not rewritten just to reformat it.
  if [ "$(jq -cS . "$tmp")" = "$(jq -cS . "$file")" ]; then
    rm -f "$tmp"
  else
    cp -p "$file" "$file.bak-$STAMP"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    echo "==> Updated $file (backup: $file.bak-$STAMP)"
  fi
}

strip_hook "$HOME/.claude/settings.json" "$HOOKS_DIR/notify.sh"
strip_hook "$HOME/.codex/hooks.json" "$HOOKS_DIR/notify.sh codex"

for f in notify.sh focus-host.sh focus-terminal.sh claude-icon.png; do
  rm -f "$HOOKS_DIR/$f"
done
echo "==> Removed hook scripts from $HOOKS_DIR"
