#!/bin/bash
# Shared installer/uninstaller config migration. Only Envelope commands are owned;
# preserve other handlers, matchers, trust metadata and settings verbatim as JSON.
envelope_config() {
  local action="$1" file="$2" agent="$3" tmp cmd legacy old_explicit old_quoted old_explicit_quoted
  [ -s "$file" ] || {
    [ "$action" = "remove" ] && return 0
    mkdir -p "$(dirname "$file")"
    printf '{}\n' > "$file"
  }
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || {
    echo "error: $file is not a JSON object; fix it and re-run." >&2
    return 1
  }
  printf -v cmd '%q %s' "$HOOKS_DIR/notify.sh" "$agent"
  legacy="$HOME/.claude/hooks/notify.sh"
  old_explicit="$legacy $agent"
  printf -v old_quoted '%q' "$legacy"
  printf -v old_explicit_quoted '%q %s' "$legacy" "$agent"
  [ "$agent" = "codex" ] && legacy="$old_explicit" && old_quoted="$old_explicit_quoted"
  tmp=$(mktemp)
  if ! jq --arg action "$action" --arg agent "$agent" --arg cmd "$cmd" \
    --arg legacy "$legacy" --arg old "$old_explicit" \
    --arg quoted "$old_quoted" --arg oldquoted "$old_explicit_quoted" '
    def owned: .command? as $c | [$cmd, $legacy, $old, $quoted, $oldquoted] | index($c) != null;
    # Keep correctly installed entries intact, including Codex trust hashes.
    if .hooks then
      .hooks |= (with_entries(.value |= (
        map(.hooks |= map(select((owned and ($action == "remove" or .command != $cmd)) | not)))
        | map(select((.hooks | length) > 0))))
        | with_entries(select((.value | length) > 0)))
    else . end
    | if $action == "remove" then . else
      (["Stop", "PreCompact", "UserPromptSubmit"] +
        (if $agent == "claude" then ["Notification"] else ["PermissionRequest"] end)) as $events
      | reduce $events[] as $event (.;
          if any(.hooks[$event][]?; (.matcher // "") as $m |
            ($m == "" or $m == "*") and any(.hooks[]?; .command? == $cmd)) then .
          else .hooks[$event] = ((.hooks[$event] // []) + [{hooks: [{type:"command", command:$cmd, timeout:10}]}]) end)
      | "(^|[_.])(AskUserQuestion|request_user_input(_async)?)$" as $questions
      | if any(.hooks.PreToolUse[]?; .matcher == $questions and any(.hooks[]?; .command? == $cmd)) then .
        else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{matcher:$questions, hooks:[{type:"command", command:$cmd, timeout:10}]}]) end
    end
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ "$(jq -cS . "$tmp")" != "$(jq -cS . "$file")" ]; then
    cp -p "$file" "$file.bak-$STAMP"
    cat "$tmp" > "$file"
    printf '==> Updated %s (backup: %s.bak-%s)\n' "$file" "$file" "$STAMP"
  fi
  rm -f "$tmp"
}
