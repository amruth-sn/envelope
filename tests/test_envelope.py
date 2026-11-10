"""Isolated hook/config regressions. Never post real desktop notifications."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


class EnvelopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="envelope-test-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "user's home with spaces"
        self.home.mkdir()
        self.log = Path(self.tmp.name) / "notifications.jsonl"
        notifier = Path(self.tmp.name) / "notifier"
        notifier.write_text('''#!/usr/bin/python3
import json, os, sys
with open(os.environ['ENVELOPE_TEST_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
''')
        notifier.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("CLAUDE", "CODEX", "AGENT_NOTIFY", "XDG_DATA_HOME", "ITERM", "TMUX"))}
        self.env.update(HOME=str(self.home), TMPDIR=self.tmp.name,
                        AGENT_NOTIFY_NOTIFIER=str(notifier), AGENT_NOTIFY_TTL="1",
                        AGENT_NOTIFY_SKIP_IF_FOCUSED="0", ENVELOPE_SKIP_BREW="1",
                        ENVELOPE_TEST_LOG=str(self.log), __CFBundleIdentifier="com.openai.codex")
        self.payload = dict(hook_event_name="Stop", session_id="root-session",
                            cwd="/projects/demo", model="gpt-6.1-sol",
                            last_assistant_message="All done")

    def run_script(self, script, *args, payload=None, env=None, check=True):
        return subprocess.run(["/bin/bash", str(REPO / script), *args],
                              input=json.dumps(payload) if payload is not None else "",
                              text=True, capture_output=True, env=env or self.env, check=check)

    def notify(self, agent="codex", **fields):
        payload = dict(self.payload, **fields)
        args = [] if agent is None else [agent]
        result = self.run_script("hooks/notify.sh", *args, payload=payload)
        self.assertEqual(result.stdout, "", "hooks must not return approval decisions")
        self.assertEqual(result.stderr, "")
        return self.posts()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def posts(self):
        return [args for args in self.calls() if "-title" in args]

    def value(self, args, key):
        return args[args.index(key) + 1]

    def transcript(self, *records):
        path = Path(self.tmp.name) / "rollout.jsonl"
        path.write_text("\n".join(json.dumps(r) for r in records) + "\n")
        return str(path)

    def config(self, provider, value):
        path = self.home / (".claude/settings.json" if provider == "claude" else ".codex/hooks.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def test_provider_icons_and_click_destination(self):
        for agent, icon, bundle in [("claude", "claude", "com.anthropic.claudefordesktop"),
                                    ("codex", "chatgpt", "com.openai.codex"),
                                    ("chatgpt", "chatgpt", "com.openai.codex")]:
            with self.subTest(agent=agent):
                self.env['__CFBundleIdentifier'] = bundle
                post = self.notify(agent)[-1]
                self.assertTrue(self.value(post, "-contentImage").endswith(f"{icon}-icon.png"))
                self.assertNotIn("-appIcon", post)  # removed in terminal-notifier 3
                click = shlex.split(self.value(post, "-execute"))
                self.assertEqual(click[1], bundle)
                if agent != "claude":
                    self.assertEqual(click[-1], "codex://threads/root-session")
                self.assertIn("finished in demo", self.value(post, "-title"))

    def test_unknown_provider_and_events_do_not_become_claude_or_finished(self):
        self.assertEqual(self.notify(None), [])
        self.assertEqual(self.notify("typo"), [])
        self.assertEqual(self.notify(hook_event_name="SubagentStop"), [])
        self.assertEqual(self.notify(hook_event_name="SessionStart"), [])
        result = subprocess.run(["bash", str(REPO / "hooks/notify.sh"), "codex"],
                                input="not JSON", text=True, capture_output=True, env=self.env)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_infers_codex_without_defaulting_to_claude(self):
        path = self.transcript({"type": "session_meta", "payload": {"source": "vscode"}})
        post = self.notify(None, transcript_path=path)[-1]
        self.assertTrue(self.value(post, "-title").startswith("Codex GPT-6.1-sol"))

    def test_subagents_and_guardians_are_silent(self):
        for source in [{"subagent": {"other": "guardian"}},
                       {"subagent": {"thread_spawn": {"parent_thread_id": "parent"}}}]:
            path = self.transcript({"type": "session_meta", "payload": {"source": source}})
            for event in ["Stop", "PermissionRequest", "PreToolUse", "PreCompact"]:
                self.assertEqual(self.notify(transcript_path=path, hook_event_name=event,
                                             tool_name="request_user_input"), [])
        for agent in ["claude", "codex"]:
            for event in ["Notification", "PreToolUse", "Stop", "PermissionRequest"]:
                self.assertEqual(self.notify(agent, agent_id="child", hook_event_name=event), [])
            self.assertEqual(self.notify(agent, transcript_path="/tmp/session/subagents/agent-abc.jsonl"), [])
        self.assertEqual(self.notify("claude", transcript_path=self.transcript({"isSidechain": True})), [])

    def test_auto_review_permissions_are_quiet_but_root_questions_notify(self):
        records = [{"type": "session_meta", "payload": {"source": "vscode"}},
                   {"type": "turn_context", "payload": {"approvals_reviewer": "auto_review", "effort": "xhigh"}}]
        # Current context may be far from the end, and JSON may contain spaces.
        records += [{"type": "event_msg", "payload": {}}] * 450
        path = self.transcript(*records)
        self.assertEqual(self.notify(hook_event_name="PermissionRequest", transcript_path=path), [])
        post = self.notify(hook_event_name="PreToolUse", transcript_path=path,
                           tool_name="functions.request_user_input_async",
                           tool_input={"questions": [{"title": "Approve the final design?"}]})[-1]
        self.assertEqual(self.value(post, "-message"), "Approve the final design?")
        self.assertIn("XHigh: needs you", self.value(post, "-title"))

    def test_effective_reviewer_overrides_config_and_payload_overrides_transcript(self):
        config = self.home / ".codex/config.toml"
        config.parent.mkdir()
        config.write_text("approvals_reviewer='auto_review' # default\n")
        self.assertEqual(self.notify(hook_event_name="PermissionRequest"), [])
        path = self.transcript({"type": "turn_context", "payload": {"approvals_reviewer": "user"}})
        post = self.notify(hook_event_name="PermissionRequest", transcript_path=path,
                           tool_name="Bash", tool_input={"command": ["git", "push"]})[-1]
        self.assertEqual(self.value(post, "-message"), "git push")
        count = len(self.posts())
        self.notify(hook_event_name="PermissionRequest", transcript_path=path, approvals_reviewer="auto_review")
        self.assertEqual(len(self.posts()), count)

    def test_root_question_tool_allowlist(self):
        for tool in ["AskUserQuestion", "request_user_input", "request_user_input_async",
                     "functions.request_user_input", "mcp__ui__request_user_input_async"]:
            post = self.notify(hook_event_name="PreToolUse", tool_name=tool,
                               tool_input={"questions": [{"question": "Which color?"}]})[-1]
            self.assertEqual(self.value(post, "-message"), "Which color?")
        count = len(self.posts())
        self.notify(hook_event_name="PreToolUse", tool_name="Bash")
        self.assertEqual(len(self.posts()), count)

    def test_both_providers_compact_and_clear_when_user_replies(self):
        for agent in ["claude", "codex"]:
            post = self.notify(agent, hook_event_name="PreCompact", trigger="manual")[-1]
            self.assertIn("compacting context", self.value(post, "-title"))
            self.assertEqual(self.value(post, "-sound"), "Pop")
            count = len(self.posts())
            self.notify(agent, hook_event_name="UserPromptSubmit")
            self.assertEqual(len(self.posts()), count)
            self.assertIn(["-remove", f"{agent}-root-session"], self.calls())

    def test_expiry_does_not_remove_replacement(self):
        self.env['AGENT_NOTIFY_TTL'] = "1"
        self.notify()
        time.sleep(0.6)
        self.notify()
        time.sleep(0.6)
        self.assertNotIn(["-remove", "codex-root-session"], self.calls())
        time.sleep(0.7)
        self.assertIn(["-remove", "codex-root-session"], self.calls())

    def test_installer_migrates_preserves_and_is_idempotent(self):
        legacy = self.home / '.claude/hooks/notify.sh'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('#!/bin/bash\nexit 42\n')
        legacy.chmod(0o755)
        for agent in ["claude", "codex"]:
            old = str(self.home / ".claude/hooks/notify.sh") + (" codex" if agent == "codex" else "")
            self.config(agent, {"custom": True, "hooks": {"Stop": [{"matcher": "", "hooks": [
                {"type": "command", "command": old},
                {"type": "command", "command": "other-hook", "trusted_hash": "keep"}]}]}})
        self.run_script("install.sh", "--link")
        self.assertIn('compatibility entry point', legacy.read_text())
        result = subprocess.run([str(legacy), 'codex'], input=json.dumps(self.payload),
                                env=self.env, text=True, capture_output=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
        self.assertEqual(len(self.posts()), 1)
        snapshots = {}
        for agent in ["claude", "codex"]:
            path = self.home / (".claude/settings.json" if agent == "claude" else ".codex/hooks.json")
            data = json.loads(path.read_text())
            self.assertTrue(data['custom'])
            self.assertIn({"type": "command", "command": "other-hook", "trusted_hash": "keep"},
                          data['hooks']['Stop'][0]['hooks'])
            commands = [h['command'] for groups in data['hooks'].values() for g in groups for h in g['hooks']]
            ours = [c for c in commands if c != "other-hook"]
            self.assertEqual(len(ours), 5)
            self.assertTrue(all(shlex.split(c) == [str(self.home / '.local/share/envelope/hooks/notify.sh'), agent] for c in ours))
            self.assertEqual(len(list(path.parent.glob(path.name + '.bak-*'))), 1)
            # A rerun must not drop Codex's per-handler trust metadata.
            data['hooks']['Stop'][-1]['hooks'][0]['trusted_hash'] = 'reviewed'
            path.write_text(json.dumps(data))
            snapshots[path] = path.read_bytes()
        self.run_script("install.sh", "--link")
        for path, before in snapshots.items():
            self.assertEqual(path.read_bytes(), before)
        self.run_script("uninstall.sh")
        for path in snapshots:
            self.assertEqual(json.loads(path.read_text()), {"custom": True, "hooks": {
                "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "other-hook", "trusted_hash": "keep"}]}]}})
        self.run_script("uninstall.sh")

    def test_disabled_provider_untouched(self):
        path = self.config("claude", {"custom": "keep formatting"})
        before = path.read_bytes()
        self.run_script("install.sh", "--no-claude")
        self.assertEqual(path.read_bytes(), before)
        self.assertTrue((self.home / '.codex/hooks.json').exists())

    def test_test_script_requires_provider(self):
        result = self.run_script("test.sh", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


if __name__ == '__main__':
    unittest.main()
