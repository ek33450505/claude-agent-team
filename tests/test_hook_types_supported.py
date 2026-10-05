"""Guard: every registered hook uses a hook `type` its event actually supports.

Source: Claude Code hooks docs, "Prompt-based hooks" event-support lists
(fetched 2026-10-05). `prompt` and `agent` hooks are only supported on a subset
of events; on any other event Claude Code errors at runtime (a `prompt` hook on
PostCompact failed live with "Prompt stop hooks are not yet supported outside
REPL"). `http` hooks are not supported on SessionStart or Setup.

Scans every managed-settings.d/*.json fragment AND the repo-root settings.json,
walking hooks.<Event>[].hooks[]. Each violation is reported as
`<file>:<Event>:<type>`.
"""

import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

KNOWN_TYPES = {"command", "http", "mcp_tool", "prompt", "agent"}

# Events that accept `prompt` AND `agent` hooks.
PROMPT_AGENT_OK = {
    "PermissionDenied",
    "PostToolBatch",
    "PostToolUse",
    "PostToolUseFailure",
    "PreToolUse",
    "Stop",
    "SubagentStop",
    "TaskCompleted",
    "TaskCreated",
    "TeammateIdle",
    "UserPromptExpansion",
    "UserPromptSubmit",
}
# PermissionRequest accepts `prompt` but NOT `agent`.
PROMPT_ONLY_OK = {"PermissionRequest"}

# Events where `http` hooks are unsupported.
HTTP_UNSUPPORTED = {"SessionStart", "Setup"}


def _settings_files():
    files = sorted((REPO / "managed-settings.d").glob("*.json"))
    files.append(REPO / "settings.json")
    return files


def _iter_hook_entries(path):
    """Yield (event, hook_type) for every hook entry in one settings file."""
    data = json.loads(path.read_text())
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        return
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks", []):
                if isinstance(hook, dict):
                    yield event, hook.get("type")


def _violation(event, hook_type):
    if hook_type not in KNOWN_TYPES:
        return True
    if hook_type == "prompt" and event not in PROMPT_AGENT_OK | PROMPT_ONLY_OK:
        return True
    if hook_type == "agent" and event not in PROMPT_AGENT_OK:
        return True
    if hook_type == "http" and event in HTTP_UNSUPPORTED:
        return True
    return False


class HookTypesSupportedTest(unittest.TestCase):
    def test_hook_types_supported_by_event(self):
        violations = []
        visited = 0
        for path in _settings_files():
            self.assertTrue(path.is_file(), f"missing settings file: {path}")
            for event, hook_type in _iter_hook_entries(path):
                visited += 1
                if _violation(event, hook_type):
                    violations.append(f"{path.name}:{event}:{hook_type}")
        # Non-vacuity: a walk that visited nothing proves nothing.
        self.assertGreater(
            visited, 20, f"walk visited only {visited} hook entries (expected > 20)"
        )
        self.assertEqual(
            violations,
            [],
            "hook type not supported on event (file:Event:type): "
            + ", ".join(violations),
        )


if __name__ == "__main__":
    unittest.main()
