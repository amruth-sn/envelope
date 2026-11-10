#!/bin/bash
# Posts sample notifications through the installed hook, without a real agent session.
#   ./test.sh claude     Claude "finished"
#   ./test.sh codex      Codex "finished"
#   ./test.sh claude Notification | PreCompact      other events
# Set AGENT_NOTIFY_TTL=10 to watch the notification expire after 10 seconds.

set -euo pipefail

agent="${1:-}"
case "$agent" in
  claude|codex) ;;
  chatgpt) agent=codex ;;
  *) echo "usage: $0 <claude|codex|chatgpt> [Stop|Notification|PermissionRequest|PreCompact|PreToolUse]" >&2; exit 2 ;;
esac
event="${2:-Stop}"
hook="${XDG_DATA_HOME:-$HOME/.local/share}/envelope/hooks/notify.sh"
[ -x "$hook" ] || { echo "error: $hook not installed; run ./install.sh first" >&2; exit 1; }

payload=$(jq -nc --arg e "$event" --arg cwd "$PWD" '{
  hook_event_name: $e, cwd: $cwd, session_id: "envelope-test",
  message: "Envelope test: the agent needs your attention.",
  approvals_reviewer: "user",
  tool_name: "request_user_input",
  tool_input: {questions: [{question: "Envelope test: which option do you prefer?"}], description: "Envelope test: approval requested."},
  last_assistant_message: "Envelope test: click this notification to jump back to the session.",
  trigger: "manual"
}')

printf '%s' "$payload" | "$hook" "$agent"
echo "Sent a test $event notification for $agent."
