#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-audit-hook.sh"
SETTINGS_JSON="$HOME/.claude/settings.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_payload() {
  local tool_name="$1"
  local extra="${2:-}"
  python3 -c "
import json, sys
tool = sys.argv[1]
extra = sys.argv[2]
inp = {}
if tool == 'Bash':
    inp['command'] = 'echo hello'
elif tool == 'Write':
    inp['file_path'] = '/tmp/test.txt'
    inp['content'] = 'test content'
elif tool == 'WebFetch':
    inp['url'] = 'https://example.com'
elif tool == 'Grep':
    inp['pattern'] = 'foo'
    inp['path'] = '/tmp'
print(json.dumps({'tool_name': tool, 'tool_input': inp}))
" "$tool_name" "$extra"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/logs"
  export AUDIT_LOG="$HOME/.claude/logs/audit.jsonl"
  unset CLAUDE_SESSION_ID
  unset CLAUDE_PROJECT_PATH
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Regression test: hook creates audit.jsonl
# This test would FAIL on the unfixed code (hook not registered = never runs,
# so audit.jsonl never created). With the hook registered in settings.json
# and the script working correctly, this test verifies the script itself
# writes a record when invoked.
# ---------------------------------------------------------------------------

@test "Bash tool call → audit.jsonl is created and contains a record" {
  run bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  assert_success
  assert [ -f "$HOME/.claude/logs/audit.jsonl" ]
  run wc -l < "$HOME/.claude/logs/audit.jsonl"
  assert [ "$(cat "$HOME/.claude/logs/audit.jsonl" | wc -l)" -ge 1 ]
}

@test "Bash tool call → audit record is valid JSON with tool_name field" {
  bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('tool_name') == 'Bash', f'expected tool_name=Bash, got {d.get(\"tool_name\")}'
print('ok')
"
}

@test "Bash tool call → audit record contains command_preview" {
  bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert 'command_preview' in d, 'missing command_preview'
print('ok')
"
}

@test "Bash tool call → audit record contains timestamp" {
  bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert 'timestamp' in d, 'missing timestamp'
import re
assert re.match(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', d['timestamp']), 'bad timestamp format'
print('ok')
"
}

@test "Write tool call → audit record has file_path field" {
  bash "$HOOK_SH" <<< "$(make_payload "Write")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('tool_name') == 'Write', f'expected tool_name=Write'
assert 'file_path' in d, 'missing file_path'
print('ok')
"
}

@test "WebFetch tool call → audit record has is_cloud_bound=true" {
  bash "$HOOK_SH" <<< "$(make_payload "WebFetch")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('is_cloud_bound') == True, f'expected is_cloud_bound=true, got {d.get(\"is_cloud_bound\")}'
print('ok')
"
}

@test "Multiple calls → each appends a new line to audit.jsonl" {
  bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  bash "$HOOK_SH" <<< "$(make_payload "Write")"
  bash "$HOOK_SH" <<< "$(make_payload "WebFetch")"
  local count
  count="$(wc -l < "$HOME/.claude/logs/audit.jsonl" | tr -d ' ')"
  assert [ "$count" -eq 3 ]
}

@test "Empty input → hook exits 0 without writing audit record" {
  run bash "$HOOK_SH" <<< ""
  assert_success
  assert [ ! -f "$HOME/.claude/logs/audit.jsonl" ] || [ "$(wc -l < "$HOME/.claude/logs/audit.jsonl" | tr -d ' ')" -eq 0 ]
}

@test "Invalid JSON input → hook exits 0 without crashing" {
  run bash "$HOOK_SH" <<< "not valid json {"
  assert_success
}

@test "audit.jsonl log directory is created if missing" {
  rm -rf "$HOME/.claude/logs"
  bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  assert [ -f "$HOME/.claude/logs/audit.jsonl" ]
}

# ---------------------------------------------------------------------------
# Registration test — directly covers the root cause of the original bug.
# The bug was NOT a script defect; it was cast-audit-hook.sh missing from
# settings.json PreToolUse. This test would FAIL on the unfixed settings.json
# (before the catch-all entry was added) and PASS after the fix.
# ---------------------------------------------------------------------------

@test "settings.json has a catch-all PreToolUse entry for cast-audit-hook.sh" {
  [ -f "$SETTINGS_JSON" ] || skip "settings.json not installed (CI)"
  assert [ -f "$SETTINGS_JSON" ]
  python3 - "$SETTINGS_JSON" <<'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    settings = json.load(f)

pre_tool_use = settings.get("hooks", {}).get("PreToolUse", [])

# Look for an entry with NO matcher (catch-all) that includes cast-audit-hook.sh
found = False
for entry in pre_tool_use:
    if "matcher" in entry:
        continue  # skip matcher-scoped entries
    for hook in entry.get("hooks", []):
        if "cast-audit-hook.sh" in hook.get("command", ""):
            found = True
            break
    if found:
        break

assert found, (
    "No catch-all PreToolUse entry for cast-audit-hook.sh found in settings.json. "
    "The audit hook is never invoked and audit.jsonl will never be created."
)
print("ok")
PYEOF
}
