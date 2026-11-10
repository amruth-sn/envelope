#!/bin/bash
# Click target for Claude Code notifications — dismisses the alert, then focuses the
# iTerm2 session / tmux pane that the notifying Claude instance runs in.
# Usage: focus-terminal.sh [iterm-session-uuid] [tmux-pane-id] [notification-group]
# Runs under terminal-notifier's minimal environment: use absolute paths.

iterm_uuid="${1:-}"
tmux_pane="${2:-}"
group="${3:-}"

[ -n "$group" ] && /opt/homebrew/bin/terminal-notifier -remove "$group" >/dev/null 2>&1

TMUX_BIN=$(command -v tmux || echo /opt/homebrew/bin/tmux)

if [ -n "$tmux_pane" ] && [ -x "$TMUX_BIN" ]; then
  target=$("$TMUX_BIN" display-message -p -t "$tmux_pane" '#{session_name}:#{window_index}' 2>/dev/null)
  if [ -n "$target" ]; then
    client=$("$TMUX_BIN" list-clients -F '#{client_name}' 2>/dev/null | head -1)
    [ -n "$client" ] && "$TMUX_BIN" switch-client -c "$client" -t "$target" 2>/dev/null
    "$TMUX_BIN" select-window -t "$target" 2>/dev/null
    "$TMUX_BIN" select-pane -t "$tmux_pane" 2>/dev/null
  fi
  # ITERM_SESSION_ID inside tmux can be stale (captured at server start), so don't
  # trust it to pick a session — just bring iTerm forward; the pane is now active.
  /usr/bin/osascript -e 'tell application "iTerm2" to activate' 2>/dev/null
  exit 0
fi

if [ -n "$iterm_uuid" ]; then
  /usr/bin/osascript - "$iterm_uuid" <<'EOF' 2>/dev/null
on run argv
  set targetId to item 1 of argv
  tell application "iTerm2"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as text) is equal to targetId then
            select s
            select t
            select w
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
end run
EOF
  exit 0
fi

/usr/bin/osascript -e 'tell application "iTerm2" to activate' 2>/dev/null
exit 0
