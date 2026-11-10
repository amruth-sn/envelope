# envelope

macOS notifications for Claude Code (CLI or desktop) and Codex (CLI, IDE, or local
ChatGPT Work chats). One shared hook gives both providers the same notification
layout, sounds, expiry, and click behavior, with their own names and icons.

## What you get

| Event | Status / sound | Claude Code | Codex / local Work |
|---|---|---|---|
| Main agent finishes | `finished` / Glass | `Stop` | `Stop` |
| User-facing permission prompt | `needs you` / Sosumi | `Notification` | `PermissionRequest` when reviewed by the user |
| Main agent asks a question | `needs you` / Sosumi | `PreToolUse` on `AskUserQuestion` | `PreToolUse` on `request_user_input` and `request_user_input_async` |
| Context compaction starts | `compacting context` / Pop | `PreCompact` | `PreCompact` |
| User sends a new message | Clears the session's notification | `UserPromptSubmit` | `UserPromptSubmit` |

- **Title:** `<Provider> <Model> <Effort>[ Fast]: <status> in <dir>`.
  Model, effort, and Fast are included when available from the payload, transcript,
  or provider settings.
- **Image:** Claude for Claude Code; ChatGPT for Codex and local Work. The small
  system icon and Notification Center permissions belong to `terminal-notifier`;
  version 3 removed per-notification app-icon overrides.
- **Body:** the final message, question, permission description, or compaction reason.
- **Click:** activates the host app. Claude Code desktop and local ChatGPT Work also
  get a session/thread deep link. iTerm2 selects the session or tmux pane. Other
  terminals and IDEs are activated without selecting a particular tab.
- **Expiry:** removes the notification after five minutes. A new notification from
  the same provider/session replaces the old one; its predecessor cannot expire it.
- **Focus:** skips notifications from the exact iTerm2 session already in front of
  you (except tmux, whose recorded iTerm session can be stale).

### Subagents and automatic review

Only the main agent notifies. Child questions, permissions, compactions, completion,
reviewer agents, and `SubagentStop` are silent. Identification uses the hook's
`agent_id`, Claude subagent paths/sidechain metadata, and Codex session metadata
(including worker and guardian sources). The main agent can relay a child's question
to the user, at which point it notifies normally.

Codex's `PermissionRequest` happens **before** approval review; it is not a signal
that a human is being asked. Envelope suppresses that event when the effective
reviewer is `auto_review` (or the older `guardian_subagent`). It prefers a reviewer
in the payload, then the latest transcript turn context, then the top-level user
config. Manual-review permissions still notify. Root questions and completion still
notify in automatic-review mode. Envelope never approves or denies an action and
never changes the selected approval policy.

There is no documented post-review, human-prompt hook. A rejected review that needs
human attention is reported when the root agent asks a question or ends its turn.
If the runtime omits reviewer metadata and uses a project/profile override, the
user-config fallback may be incomplete. Transcript fields are a best-effort fallback,
not a stable provider API. See the [Codex hooks reference](https://learn.chatgpt.com/docs/hooks)
and [Claude Code hooks reference](https://code.claude.com/docs/en/hooks).

## Requirements

- macOS, Apple Silicon or Intel
- [Homebrew](https://brew.sh) and `jq` (`brew install jq` if missing)
- Claude Code and/or Codex installed

The installer installs or upgrades `terminal-notifier` to at least 3.1.0, needed for
notification removal on current macOS.

## Setup

```bash
git clone https://github.com/amruth-sn/envelope.git ~/envelope
~/envelope/install.sh
~/envelope/test.sh claude
~/envelope/test.sh codex
```

Allow **terminal-notifier** in **System Settings > Notifications**, choosing Banners
or Alerts. Also check Focus / Do Not Disturb if a test does not appear.

Review the Codex hooks once using `/hooks` in the CLI or **Settings > Hooks** in the
desktop app. New or changed hook definitions need review; the installer does not
mark hooks trusted for you. Restart existing Claude Code / Codex chats to load the
new registrations.

The installer backs up changed config files, preserves unrelated hooks and settings,
and can be rerun without duplicating registrations or dropping existing trust data.
Upgrading migrates the old `~/.claude/hooks/notify.sh` commands to the shared location.
The legacy entry point forwards to the new hook so existing chats get the fixes
immediately. Legacy click handlers remain until uninstall so notifications already
posted can still open their original target.

| Option | Effect |
|---|---|
| `--link` | Symlink shared files to this checkout; `git pull` updates the installed scripts. Keep the checkout in place. |
| `--no-claude` | Skip changes to Claude settings. |
| `--no-codex` | Skip changes to Codex hooks. |
| `--iterm-status` | Also register iTerm2's existing `~/.config/iterm2/cc-status` helper for Claude Code. |

Without `--link`, rerun `install.sh` after pulling updates.

## Files and commands

| Path | Content |
|---|---|
| `~/.local/share/envelope/hooks/` | Shared scripts, Claude icon, and ChatGPT icon. Respects `XDG_DATA_HOME`. |
| `~/.claude/settings.json` | Explicit `notify.sh claude` registrations. |
| `~/.codex/hooks.json` | Explicit `notify.sh codex` registrations. Respects `CODEX_HOME`. |

Both providers use the same number of arguments. `notify.sh chatgpt` is also accepted
as an alias for `codex`. A bare `notify.sh` only works when the payload/transcript or
agent environment identifies its provider; unknown callers are skipped. It never
defaults to Claude. Config commands and notification click targets are shell-quoted
so installation paths with spaces and apostrophes work.

`~/.codex/config.toml` is not modified. If an existing legacy `notify` command also
posts desktop notifications, disable that registration yourself to avoid duplicates.

## Configuration

Set variables in the agent's launch environment (or Claude Code's settings `env`).

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_NOTIFY_TTL` | `300` | Seconds until expiry. |
| `AGENT_NOTIFY_SKIP_IF_FOCUSED` | `1` | Skip the frontmost originating iTerm2 session; `0` always notifies. |
| `AGENT_NOTIFY_NOTIFIER` | Homebrew `terminal-notifier` | Override the notifier executable, useful for isolated tests. |

`CLAUDE_NOTIFY_SKIP_IF_FOCUSED` is still accepted for older setups; the neutral
variable takes precedence. Replace the provider's `claude-icon.png` or
`chatgpt-icon.png` in the shared directory to customize its image. The bundled
ChatGPT image comes from the installed ChatGPT desktop app.

## Testing

```bash
~/envelope/test.sh claude
~/envelope/test.sh codex
~/envelope/test.sh chatgpt PreToolUse
~/envelope/test.sh claude Notification
~/envelope/test.sh codex PermissionRequest
~/envelope/test.sh codex PreCompact
AGENT_NOTIFY_TTL=10 ~/envelope/test.sh codex
python3 -m unittest discover -s ~/envelope/tests -v
```

`test.sh` requires a provider. Synthetic permission tests explicitly select manual
review so they remain visible even if your real chats use automatic review. The
Python suite uses a fake notifier and temporary home directories; it never posts
real notifications or modifies your live agent settings.

## Troubleshooting and limits

- If tests work but real chats do not, review the Codex hooks and restart the chat.
  Inspect registrations with `jq .hooks ~/.claude/settings.json` or
  `jq .hooks ~/.codex/hooks.json`.
- For iTerm click-through, allow terminal-notifier under **System Settings > Privacy
  & Security > Automation**. Other IDEs/terminals only get app activation.
- Host detection uses `__CFBundleIdentifier`, terminal environment variables, and the
  ancestor process tree. Detached processes fall back to their provider's desktop app.
- Local-only ChatGPT Work and Codex support these command hooks. Ordinary chat and
  cloud-orchestrated chats do not run this local hook setup. This is a runtime
  boundary for both providers, not a reason to use Claude branding for OpenAI events.
  See [hook execution environments](https://learn.chatgpt.com/docs/hooks#managed-hooks-from-requirementstoml).
- Desktop rendering, live event delivery, and click-through need a smoke test in each
  host. The automated suite verifies payload handling and routing, not macOS UI.

## Uninstall

```bash
~/envelope/uninstall.sh
```

Removes current and legacy Envelope registrations and files, backing up changed
configs. Other hooks, settings, backups, and `terminal-notifier` remain installed.
