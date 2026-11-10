#!/bin/bash
# Posts sample notifications through the installed hook, without a real agent session.
#   ./test.sh            Claude "finished"
#   ./test.sh codex      Codex "finished"
#   ./test.sh claude Notification | PreCompact      other events
# Set AGENT_NOTIFY_TTL=10 to watch the notification expire after 10 seconds.

set -euo pipefail

agent="${1:-claude}"
event="${2:-Stop}"
hook="$HOME/.claude/hooks/notify.sh"
[ -x "$hook" ] || { echo "error: $hook not installed; run ./install.sh first" >&2; exit 1; }

payload=$(jq -nc --arg e "$event" --arg cwd "$PWD" '{
  hook_event_name: $e, cwd: $cwd, session_id: "envelope-test",
  message: "Envelope test: the agent needs your attention.",
  last_assistant_message: "Envelope test: click this notification to jump back to the session.",
  trigger: "manual"
}')

if [ "$agent" = "codex" ]; then
  printf '%s' "$payload" | "$hook" codex
else
  printf '%s' "$payload" | "$hook"
fi
echo "Sent a test $event notification for $agent."
