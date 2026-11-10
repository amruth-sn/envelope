#!/bin/bash
# macOS notification hook shared by Claude Code and Codex.
#   Claude Code: ~/.claude/settings.json  -> notify.sh            (Stop, Notification, PreCompact)
#   Codex:       ~/.codex/hooks.json      -> notify.sh codex      (Stop, PermissionRequest, PreCompact)
# Reads the hook payload JSON on stdin. Must print nothing on stdout: Codex parses
# stdout of Stop/PermissionRequest hooks as a decision.
#
# Title:    "<Provider> <Model> <Effort>[ Fast]: <status> in <dir>"
# Subtitle: the app the session runs in (Claude app / iTerm2 session / Android Studio / ...)
# Click:    focus-host.sh brings that app (and, where possible, that exact session) forward.
# Expiry:   the notification is removed from Notification Center after AGENT_NOTIFY_TTL
#           seconds (default 300) by a detached sleeper, unless a newer notification for the
#           same session replaced it first.

set -u

agent="${1:-claude}"

TN=/opt/homebrew/bin/terminal-notifier
[ -x "$TN" ] || TN=/usr/local/bin/terminal-notifier  # Intel Homebrew
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(command -v jq)
HOOKS_DIR="$HOME/.claude/hooks"
ICON="$HOOKS_DIR/claude-icon.png"
TTL="${AGENT_NOTIFY_TTL:-300}"
STATE_DIR="${TMPDIR:-/tmp}/agent-notify"
# When 1: no ping if the exact iTerm session running this agent is already frontmost.
SKIP_IF_FOCUSED="${CLAUDE_NOTIFY_SKIP_IF_FOCUSED:-1}"

input=$(cat)
jget() { printf '%s' "$input" | "$JQ" -r "$1 // empty" 2>/dev/null; }

event=$(jget '.hook_event_name')
cwd=$(jget '.cwd')
session_id=$(jget '.session_id')
transcript=$(jget '.transcript_path')

dir=""
[ -n "$cwd" ] && dir=$(basename "$cwd")
dir=${dir:-terminal}

cap() { printf '%s' "$1" | awk '{ print toupper(substr($0,1,1)) substr($0,2) }'; }

pretty_effort() {
  case "$1" in
    ""|none|null) ;;
    xhigh) printf 'XHigh' ;;
    *) cap "$1" ;;
  esac
}

# claude-opus-5-5 -> "Opus 5.5"; claude-sonnet-4-5-20250929 -> "Sonnet 4.5"
pretty_claude_model() {
  printf '%s' "$1" | sed -E 's/\[[^]]*\]$//; s/^claude-//; s/-[0-9]{8}$//' | awk -F- '{
    name = ""; ver = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+$/) ver = (ver == "" ? $i : ver "." $i)
      else name = (name == "" ? "" : name " ") toupper(substr($i,1,1)) substr($i,2)
    }
    print name (ver == "" ? "" : " " ver)
  }'
}

# gpt-6.1-sol -> "GPT-6.1-sol"
pretty_codex_model() { printf '%s' "$1" | sed -E 's/^gpt/GPT/'; }

# ---------------------------------------------------------------------------
# Model / effort / speed
# ---------------------------------------------------------------------------
provider=""
model=""
effort=""
fast=0

if [ "$agent" = "codex" ]; then
  provider="Codex"
  model=$(jget '.model')
  tier=""
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    tc=$(grep '"type":"turn_context"' "$transcript" 2>/dev/null | tail -n 1)
    ts=$(grep '"thread_settings_applied"' "$transcript" 2>/dev/null | tail -n 1)
    [ -z "$model" ] && model=$(printf '%s' "$tc" | "$JQ" -r '.payload.model // empty' 2>/dev/null)
    effort=$(printf '%s' "$tc" | "$JQ" -r '.payload.effort // .payload.reasoning_effort // empty' 2>/dev/null)
    [ -z "$effort" ] && effort=$(printf '%s' "$ts" | "$JQ" -r '.payload.thread_settings.reasoning_effort // empty' 2>/dev/null)
    tier=$(printf '%s' "$tc" | "$JQ" -r '.payload.service_tier // empty' 2>/dev/null)
    [ -z "$tier" ] && tier=$(printf '%s' "$ts" | "$JQ" -r '.payload.thread_settings.service_tier // empty' 2>/dev/null)
  fi
  cfg="$HOME/.codex/config.toml"
  toml_top() { [ -f "$cfg" ] && awk -v k="$1" '/^\[/{exit} $1==k { sub(/^[^=]*=[ \t]*/, ""); gsub(/"/, ""); print; exit }' "$cfg"; }
  [ -z "$model" ] && model=$(toml_top model)
  [ -z "$effort" ] && effort=$(toml_top model_reasoning_effort)
  [ -z "$tier" ] && tier=$(toml_top service_tier)
  case "$tier" in priority|fast) fast=1 ;; esac
  model=$(pretty_codex_model "$model")
else
  provider="Claude"
  effort=$(jget '.effort.level')
  speed=""
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    last=$(tail -n 400 "$transcript" 2>/dev/null | "$JQ" -c \
      'select(.type=="assistant" and (.isSidechain|not) and (.message.model // "<synthetic>") != "<synthetic>")
       | {m: .message.model, e: (.effort // ""), s: (.message.usage.speed // "")}' 2>/dev/null | tail -n 1)
    model=$(printf '%s' "$last" | "$JQ" -r '.m // empty' 2>/dev/null)
    [ -z "$effort" ] && effort=$(printf '%s' "$last" | "$JQ" -r '.e // empty' 2>/dev/null)
    speed=$(printf '%s' "$last" | "$JQ" -r '.s // empty' 2>/dev/null)
  fi
  [ -z "$model" ] && model=$(jget '.model')
  [ -z "$effort" ] && effort="${CLAUDE_EFFORT:-}"
  if [ -z "$model" ] || [ -z "$effort" ] || [ -z "$speed" ]; then
    settings="$HOME/.claude/settings.json"
    [ -z "$model" ] && model=$("$JQ" -r '.model // empty' "$settings" 2>/dev/null)
    [ -z "$effort" ] && effort=$("$JQ" -r '.effortLevel // empty' "$settings" 2>/dev/null)
    [ -z "$speed" ] && [ "$("$JQ" -r '.fastMode // false' "$settings" 2>/dev/null)" = "true" ] && speed=fast
  fi
  [ "$speed" = "fast" ] && fast=1
  model=$(pretty_claude_model "$model")
fi

descriptor="$provider"
[ -n "$model" ] && descriptor="$descriptor $model"
e=$(pretty_effort "$effort")
[ -n "$e" ] && descriptor="$descriptor $e"
[ "$fast" = "1" ] && descriptor="$descriptor Fast"

# ---------------------------------------------------------------------------
# Host app detection: which app should a click bring forward?
# ---------------------------------------------------------------------------
bundle="${__CFBundleIdentifier:-}"
if [ -z "$bundle" ]; then
  if [ -n "${ITERM_SESSION_ID:-}" ] || [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    bundle=com.googlecode.iterm2
  elif [ "${TERMINAL_EMULATOR:-}" = "JetBrains-JediTerm" ]; then
    bundle=com.google.android.studio
  elif [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "claude-desktop" ]; then
    bundle=com.anthropic.claudefordesktop
  elif [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ]; then
    bundle=com.apple.Terminal
  fi
fi
if [ -z "$bundle" ]; then
  # Walk up the process tree to the first ancestor inside an installed app bundle.
  # (Claude Code's own binary lives in ~/Library/Application Support/.../claude.app; skip it.)
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    { [ -z "$pid" ] || [ "$pid" -le 1 ]; } && break
    path=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$path" in
      /Applications/*.app/*|"$HOME"/Applications/*.app/*)
        app="${path%%.app/*}.app"
        bundle=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)
        [ -n "$bundle" ] && break
        ;;
    esac
  done
fi
if [ -z "$bundle" ]; then
  # Nothing identifiable (e.g. a detached daemon): fall back to the agent's desktop app.
  [ "$agent" = "codex" ] && bundle=com.openai.codex || bundle=com.anthropic.claudefordesktop
fi

iterm_uuid=""
tmux_pane=""
deeplink=""
loc=""
case "$bundle" in
  com.googlecode.iterm2)
    [ -n "${ITERM_SESSION_ID:-}" ] && iterm_uuid="${ITERM_SESSION_ID#*:}"
    tmux_pane="${TMUX_PANE:-}"
    if [ -n "$tmux_pane" ] && [ -n "${TMUX:-}" ]; then
      loc=$(tmux display-message -p -t "$tmux_pane" 'tmux #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
    fi
    [ -z "$loc" ] && [ -n "${ITERM_SESSION_ID:-}" ] && loc="iTerm ${ITERM_SESSION_ID%%:*}"
    [ -z "$loc" ] && loc="iTerm2"
    ;;
  com.google.android.studio) loc="Android Studio" ;;
  com.anthropic.claudefordesktop)
    loc="Claude app"
    host_sid="${CLAUDE_CODE_HOST_SESSION_ID:-}"
    [[ "$host_sid" =~ ^local_[A-Za-z0-9-]{1,64}$ ]] && deeplink="claude://code/continue?session=$host_sid"
    ;;
  com.openai.codex)
    loc="ChatGPT app"
    [[ "$session_id" =~ ^[A-Za-z0-9-]{1,64}$ ]] && deeplink="codex://threads/$session_id"
    ;;
  com.apple.Terminal) loc="Terminal" ;;
  *) loc=$(/usr/bin/osascript -e "name of application id \"$bundle\"" 2>/dev/null) ;;
esac

# Suppress the ping when the user is already looking at this exact iTerm session.
if [ "$SKIP_IF_FOCUSED" = "1" ] && [ -n "$iterm_uuid" ] && [ -z "$tmux_pane" ]; then
  front=$(lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null)
  case "$front" in
    *iTerm2*)
      active=$(/usr/bin/osascript -e 'tell application "iTerm2" to id of current session of current window' 2>/dev/null)
      [ "$active" = "$iterm_uuid" ] && exit 0
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Status / body / sound per event
# ---------------------------------------------------------------------------
oneline() { tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }

status=""
body=""
sound="Glass"
case "$event" in
  Notification|PermissionRequest)
    status="needs you"
    sound="Sosumi"
    if [ "$event" = "Notification" ]; then
      body=$(jget '.message' | oneline)
    else
      body=$(printf '%s' "$input" | "$JQ" -r '
        (.tool_input.description // empty),
        (.tool_input.command | if type=="array" then join(" ") elif type=="string" then . else empty end),
        ("Approve " + (.tool_name // "tool") + "?")' 2>/dev/null | head -n 1 | oneline)
    fi
    ;;
  PreCompact)
    status="compacting context"
    sound="Pop"
    trigger=$(jget '.trigger')
    case "$trigger" in
      auto) body="Context window is full; auto-compacting the conversation." ;;
      manual) body="Compacting the conversation (/compact)." ;;
      *) body="Compacting the conversation." ;;
    esac
    ;;
  *)
    status="finished"
    body=$(jget '.last_assistant_message' | oneline)
    if [ -z "$body" ] && [ "$agent" = "claude" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
      body=$("$JQ" -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty' \
        "$transcript" 2>/dev/null | oneline)
    fi
    ;;
esac

title="$descriptor: $status in $dir"
[ -z "$body" ] && body="Session in $cwd${loc:+ ($loc)}"
body=${body:0:230}
case "$body" in -*) body=" $body" ;; esac

# ---------------------------------------------------------------------------
# Post, then schedule removal
# ---------------------------------------------------------------------------
safe_sid=$(printf '%s' "${session_id:-default}" | tr -c 'A-Za-z0-9_-' '_')
group="$agent-$safe_sid"

# Only pass shell-safe values into the -execute string (it is run through a shell).
safe() { [[ "$1" =~ ^[A-Za-z0-9_.:/?=%-]*$ ]] && printf '%s' "$1"; }
click="$HOOKS_DIR/focus-host.sh '$(safe "$bundle")' '$(safe "$iterm_uuid")' '$(safe "$tmux_pane")' '$(safe "$group")' '$(safe "$deeplink")'"

args=(-title "$title" -message "$body" -sound "$sound" -group "$group" -execute "$click")
[ -n "$loc" ] && args+=(-subtitle "$loc")
[ -f "$ICON" ] && args+=(-contentImage "$ICON")

"$TN" "${args[@]}" </dev/null >/dev/null 2>&1

# A later notification for the same session reuses the group (replacing this one) and
# rewrites the token, so this sleeper then leaves the newer notification alone.
mkdir -p "$STATE_DIR" 2>/dev/null
token="$(date +%s).$$.$RANDOM"
printf '%s' "$token" > "$STATE_DIR/$group" 2>/dev/null
# perl: fork so the hook returns immediately, setsid so the sleeper leaves the hook's
# process group and survives the hook runner cleaning up after it.
/usr/bin/perl -MPOSIX=setsid -e '
  exit 0 if fork;
  setsid();
  open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
  exec @ARGV;
' /bin/bash -c '
  sleep "$1"
  if [ "$(cat "$2" 2>/dev/null)" = "$3" ]; then
    "$4" -remove "$5" >/dev/null 2>&1
    rm -f "$2"
  fi
' agent-notify-expire "$TTL" "$STATE_DIR/$group" "$token" "$TN" "$group" </dev/null >/dev/null 2>&1

exit 0
