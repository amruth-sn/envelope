#!/bin/bash
# Installs the agent notification hooks for Claude Code and Codex on macOS.
# Safe to re-run: files are overwritten in place, config entries are never duplicated,
# and every config file that changes is backed up next to the original first.
#
#   ./install.sh                 copy the scripts into ~/.claude/hooks
#   ./install.sh --link          symlink them instead, so `git pull` updates the hooks
#   ./install.sh --iterm-status  also register iTerm2's cc-status hook (if iTerm2 installed it)
#   ./install.sh --no-codex      skip the Codex side
#   ./install.sh --no-claude     skip the Claude Code side

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
ITERM_STATUS="$HOME/.config/iterm2/cc-status"
MIN_TN="3.1.0"
STAMP="$(date +%Y%m%d-%H%M%S)"

link=0
do_claude=1
do_codex=1
iterm_status=0
for arg in "$@"; do
  case "$arg" in
    --link) link=1 ;;
    --no-claude) do_claude=0 ;;
    --no-codex) do_codex=0 ;;
    --iterm-status) iterm_status=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# a >= b for dotted versions
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "macOS only (the hooks use Notification Center, osascript and open)."
command -v jq >/dev/null 2>&1 || die "jq not found. It ships with macOS 15+; otherwise: brew install jq"

if [ "${ENVELOPE_SKIP_BREW:-0}" != "1" ]; then
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh and re-run."
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    say "Installing terminal-notifier"
    brew install terminal-notifier
  fi
  tn_version="$(terminal-notifier -version 2>/dev/null | sed -E 's/[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')"
  if ! version_ge "${tn_version:-0}" "$MIN_TN"; then
    say "Upgrading terminal-notifier ${tn_version:-?} -> >= $MIN_TN (older versions cannot remove notifications)"
    brew upgrade terminal-notifier
  fi
fi

# ---------------------------------------------------------------------------
# Scripts
# ---------------------------------------------------------------------------
mkdir -p "$HOOKS_DIR"
for f in notify.sh focus-host.sh focus-terminal.sh claude-icon.png; do
  src="$REPO/hooks/$f"
  dst="$HOOKS_DIR/$f"
  [ "$src" -ef "$dst" ] && continue
  if [ -e "$dst" ] && [ ! -L "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp -p "$dst" "$dst.bak-$STAMP"
  fi
  rm -f "$dst"
  if [ "$link" = "1" ]; then ln -s "$src" "$dst"; else cp "$src" "$dst"; fi
done
chmod +x "$REPO"/hooks/*.sh "$HOOKS_DIR"/*.sh
say "Hook scripts installed in $HOOKS_DIR ($([ "$link" = "1" ] && echo symlinked || echo copied))"

# ---------------------------------------------------------------------------
# Config merging
# ---------------------------------------------------------------------------
# add_hook <file> <command> <timeout or ""> <event>...
# Adds one command hook per event unless that exact command is already registered for
# it. Everything else in the file is left as it is.
add_hook() {
  local file="$1" cmd="$2" timeout="$3"
  shift 3
  local events tmp
  events="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  mkdir -p "$(dirname "$file")"
  [ -s "$file" ] || printf '{}\n' > "$file"
  jq -e . "$file" >/dev/null 2>&1 || die "$file is not valid JSON; fix it and re-run."
  tmp="$(mktemp)"
  jq --arg cmd "$cmd" --arg timeout "$timeout" --argjson events "$events" '
    ({type: "command", command: $cmd}
      + (if $timeout == "" then {} else {timeout: ($timeout | tonumber)} end)) as $hook
    | reduce $events[] as $e (.;
        if [.hooks[$e][]?.hooks[]?.command] | index($cmd)
        then .
        else .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [$hook]}])
        end)
  ' "$file" > "$tmp"
  # Compare content, not bytes, so a file is not rewritten just to reformat it.
  if [ "$(jq -cS . "$tmp")" = "$(jq -cS . "$file")" ]; then
    rm -f "$tmp"
  else
    cp -p "$file" "$file.bak-$STAMP"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    say "Updated $file (backup: $file.bak-$STAMP)"
  fi
}

if [ "$do_claude" = "1" ]; then
  add_hook "$CLAUDE_SETTINGS" "$HOOKS_DIR/notify.sh" 10 Notification Stop PreCompact
  if [ "$iterm_status" = "1" ]; then
    if [ -x "$ITERM_STATUS" ]; then
      add_hook "$CLAUDE_SETTINGS" "$ITERM_STATUS" "" \
        Notification PermissionRequest PostToolUse PreToolUse SessionEnd SessionStart \
        Stop StopFailure SubagentStop UserPromptSubmit
    else
      warn "$ITERM_STATUS not found; skipped. Enable the Claude Code integration in iTerm2 first, then re-run with --iterm-status."
    fi
  fi
  say "Claude Code hooks registered in $CLAUDE_SETTINGS"
fi

if [ "$do_codex" = "1" ]; then
  add_hook "$CODEX_HOOKS" "$HOOKS_DIR/notify.sh codex" 10 Stop PermissionRequest PreCompact
  say "Codex hooks registered in $CODEX_HOOKS"
fi

cat <<MSG

Done. Remaining manual steps:
  1. Allow notifications for terminal-notifier:
       System Settings > Notifications > terminal-notifier > Allow, style "Alerts" or "Banners".
     Send a test to make it show up in that list:  ./test.sh
  2. Codex only: trust the new hooks once. Run /hooks in the Codex CLI, or open
     Settings > Hooks in the ChatGPT desktop app, and approve the three notify.sh entries.
  3. Restart any running Claude Code / Codex sessions so they pick up the hooks.
MSG
