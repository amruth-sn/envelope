#!/bin/bash
# Click target for agent notifications posted by notify.sh: dismisses the alert, then
# brings forward the app the session runs in.
#   iTerm2:          the exact iTerm session / tmux pane
#   Claude app:      the exact Code session via claude://code/continue?session=local_...
#   ChatGPT (Codex): the exact thread via codex://threads/<id>
#   anything else:   just activates the app (e.g. Android Studio)
# Usage: focus-host.sh <bundle-id> [iterm-session-uuid] [tmux-pane-id] [group] [deeplink]
# Runs under terminal-notifier's minimal environment: use absolute paths.

bundle="${1:-}"
iterm_uuid="${2:-}"
tmux_pane="${3:-}"
group="${4:-}"
deeplink="${5:-}"

TN=/opt/homebrew/bin/terminal-notifier
[ -x "$TN" ] || TN=/usr/local/bin/terminal-notifier  # Intel Homebrew
[ -n "$group" ] && "$TN" -remove "$group" >/dev/null 2>&1

if [ "$bundle" = "com.googlecode.iterm2" ]; then
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
fi

[ -n "$bundle" ] && /usr/bin/open -b "$bundle" 2>/dev/null
# The deep link selects the session inside the app; if the app ignores it (e.g. desktop
# entry points disabled), the activation above still lands the user in the right app.
[ -n "$deeplink" ] && /usr/bin/open "$deeplink" 2>/dev/null
exit 0
