# envelope

macOS notifications for Claude Code and Codex sessions. When an agent finishes, needs
you, or starts compacting its context, a notification appears in the top right of the
screen. Clicking it takes you back to the app the session is running in, and where
possible to the exact session.

One script (`hooks/notify.sh`) serves both agents, so the notifications look and behave
the same.

## What you get

| Event | Title status | Sound | Claude Code hook | Codex hook |
|---|---|---|---|---|
| Agent finished its turn | `finished` | Glass | `Stop` | `Stop` |
| Agent is waiting on you | `needs you` | Sosumi | `Notification` | `PermissionRequest` |
| Context is being compacted | `compacting context` | Pop | `PreCompact` | `PreCompact` |

- **Title:** `<Provider> <Model> <Effort>[ Fast]: <status> in <dir>`, for example
  `Claude Opus 5.5 High: finished in my-project`. `Fast` only appears in fast mode.
- **Subtitle:** where the session lives (Claude app, iTerm2 session, Android Studio, ...).
- **Body:** the agent's last message, the permission being requested, or the compaction reason.
- **Click:** brings the hosting app forward.
  - Claude desktop app: opens that exact Code session.
  - ChatGPT / Codex desktop app: opens that exact thread.
  - iTerm2: selects that exact session, or the tmux window and pane.
  - Android Studio, Terminal and anything else: activates the app.
- **Expiry:** each notification removes itself after 5 minutes. A newer notification from
  the same session replaces the older one instead of stacking.
- No notification is sent if the iTerm2 session that produced it is already in front of you.

## Requirements

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- `jq` (ships with macOS 15 and later; otherwise `brew install jq`)
- Claude Code and/or Codex already installed and signed in

The installer adds `terminal-notifier` 3.1.0 or newer for you. Older versions cannot
remove notifications on current macOS, which breaks the 5-minute expiry.

## Setup on a new machine

1. Clone the repo somewhere permanent:

   ```bash
   git clone https://github.com/amruth-sn/envelope.git ~/envelope
   ```

2. Run the installer:

   ```bash
   ~/envelope/install.sh
   ```

   It installs `terminal-notifier` if needed, puts the scripts in `~/.claude/hooks/`, and
   registers the hooks in `~/.claude/settings.json` and `~/.codex/hooks.json`. Existing
   settings and hooks are kept. Any config file it changes is first copied to
   `<file>.bak-<timestamp>`. Running it again is safe and changes nothing.

3. Send a test notification:

   ```bash
   ~/envelope/test.sh
   ```

4. Allow the notifications. The first test makes `terminal-notifier` show up in
   **System Settings > Notifications**. Open it there, turn on **Allow notifications**,
   and pick **Banners** or **Alerts**. If nothing appeared in step 3, this is why. Run the
   test again afterwards. Also check that Focus / Do Not Disturb is off.

5. Codex only: trust the hooks. Codex does not run a new hook until you approve it once.
   - Codex CLI: run `/hooks` inside a session and approve the three `notify.sh codex` entries.
   - ChatGPT desktop app: **Settings > Hooks**, approve the same three entries.

6. Restart any Claude Code or Codex sessions that were already running. New sessions pick
   the hooks up automatically.

### Installer options

| Option | Effect |
|---|---|
| `--link` | Symlink the scripts into `~/.claude/hooks/` instead of copying them. `git pull` then updates the live hooks. Do not move or delete the clone afterwards. |
| `--iterm-status` | Also register iTerm2's `cc-status` helper on the Claude Code events it listens to. See [iTerm2 status helper](#iterm2-status-helper). |
| `--no-codex` | Only set up Claude Code. |
| `--no-claude` | Only set up Codex. |

Without `--link`, re-run `install.sh` after a `git pull` to update the installed copies.

## Testing

```bash
~/envelope/test.sh                      # Claude, "finished"
~/envelope/test.sh claude Notification  # Claude, "needs you"
~/envelope/test.sh claude PreCompact    # Claude, "compacting context"
~/envelope/test.sh codex                # Codex, "finished"
AGENT_NOTIFY_TTL=10 ~/envelope/test.sh  # disappears after 10 seconds
```

The test payload has no transcript, so the model in the title falls back to your
configured default. Click the notification to check that it lands in the app you ran the
test from.

## Configuration

Both are environment variables read by `notify.sh`. Set them in the environment the
agent is launched from, or in the `env` block of `~/.claude/settings.json`.

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_NOTIFY_TTL` | `300` | Seconds before a notification removes itself. |
| `CLAUDE_NOTIFY_SKIP_IF_FOCUSED` | `1` | `1` skips the notification when the originating iTerm2 session is already frontmost. `0` always notifies. |

To change the picture attached to the notification, replace
`~/.claude/hooks/claude-icon.png`.

## What the installer writes

| Path | Content |
|---|---|
| `~/.claude/hooks/notify.sh` | The hook. `notify.sh` for Claude Code, `notify.sh codex` for Codex. |
| `~/.claude/hooks/focus-host.sh` | Click handler. Activates the app and opens the session deep link. |
| `~/.claude/hooks/focus-terminal.sh` | Older iTerm2/tmux-only click handler, kept so notifications posted before an upgrade still work. |
| `~/.claude/hooks/claude-icon.png` | Image attached to each notification. |
| `~/.claude/settings.json` | Adds `notify.sh` under `hooks.Notification`, `hooks.Stop`, `hooks.PreCompact`. |
| `~/.codex/hooks.json` | Adds `notify.sh codex` under `hooks.Stop`, `hooks.PermissionRequest`, `hooks.PreCompact`. |

Hook commands are written with absolute paths based on the current `$HOME`, so nothing
needs editing per machine. `~/.codex/config.toml` is never touched; its `notify` setting
can stay pointed at whatever it already uses.

## iTerm2 status helper

`~/.config/iterm2/cc-status` is a binary that iTerm2 installs itself when you enable its
Claude Code integration. It is not part of this repo. If it exists on the machine and
the hook entries for it are missing, add them with:

```bash
~/envelope/install.sh --iterm-status
```

This registers it on `Notification`, `PermissionRequest`, `PostToolUse`, `PreToolUse`,
`SessionEnd`, `SessionStart`, `Stop`, `StopFailure`, `SubagentStop` and `UserPromptSubmit`.

## Troubleshooting

- **No notification at all.** Run `~/envelope/test.sh`. If that shows nothing, check
  System Settings > Notifications > terminal-notifier and Focus mode. If the test works
  but real sessions do not, restart the session, then check that the hook is registered:
  `jq .hooks ~/.claude/settings.json` or `cat ~/.codex/hooks.json`.
- **Codex never notifies.** The hooks are not trusted yet. See step 5.
- **Notifications never disappear.** `terminal-notifier -version` must be 3.1.0 or newer.
  Run `brew upgrade terminal-notifier`.
- **Click opens the wrong app.** The host app is detected from `__CFBundleIdentifier`,
  then terminal environment variables, then the parent process tree. Check what the
  session sees with `echo $__CFBundleIdentifier $TERM_PROGRAM $TERMINAL_EMULATOR`.
- **Click does nothing in iTerm2.** macOS asks once for permission to let
  terminal-notifier control iTerm2. Approve it under System Settings > Privacy &
  Security > Automation.

## Known limits

- The ChatGPT chat app (not Codex) has no hook mechanism, so it cannot send these.
- Android Studio is brought to the front, but the specific terminal tab is not selected.
- Not yet verified end to end: Codex hooks firing in a live session, the Codex CLI in a
  plain terminal, the `Fast` label, and click-through for every host app.

## Uninstall

```bash
~/envelope/uninstall.sh
```

Removes the `notify.sh` entries from both config files (with backups) and deletes the
four installed files. Other hooks, settings and `terminal-notifier` are left in place.
