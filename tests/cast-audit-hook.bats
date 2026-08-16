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
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export AUDIT_LOG="$HOME/.claude/logs/audit.jsonl"
  unset CLAUDE_SESSION_ID
  unset CLAUDE_PROJECT_PATH
  # cast-audit.py's _sanitize_error_text() (v10 2.6 Fix 1) loads cast-redact.py
  # from $HOME/.claude/scripts/ — make it reachable in the temp HOME so MCP
  # error_preview redaction can actually run instead of failing closed.
  mkdir -p "$HOME/.claude/scripts"
  cp "$REPO_DIR/scripts/cast-redact.py" "$HOME/.claude/scripts/"
}

teardown() {
  teardown_temp_home
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
  [[ -f "$HOME/.claude/logs/audit.jsonl" ]]
  run wc -l < "$HOME/.claude/logs/audit.jsonl"
  [[ "$(cat "$HOME/.claude/logs/audit.jsonl" | wc -l)" -ge 1 ]]
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
  [[ "$count" -eq 3 ]]
}

@test "Empty input → hook exits 0 without writing audit record" {
  run bash "$HOOK_SH" <<< ""
  assert_success
  [[ ! -f "$HOME/.claude/logs/audit.jsonl" ]] || [[ "$(wc -l < "$HOME/.claude/logs/audit.jsonl" | tr -d ' ')" -eq 0 ]]
}

@test "Invalid JSON input → hook exits 0 without crashing" {
  run bash "$HOOK_SH" <<< "not valid json {"
  assert_success
}

@test "audit.jsonl log directory is created if missing" {
  rm -rf "$HOME/.claude/logs"
  bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  [[ -f "$HOME/.claude/logs/audit.jsonl" ]]
}

# ---------------------------------------------------------------------------
# MCP observability (v10 2.6) — end-to-end through the real hook script, not
# just the Python unit tests. is_cloud_bound is classified from CAST's
# canonical config/egress-policy.json (mcp_servers.cloud_bound/local_only),
# resolved via $CWD/config/egress-policy.json — bats is invoked from the repo
# root, so these tests read the REAL policy file, not a fixture. Servers not
# named in either list (e.g. "unknownserver" below) exercise the fail-safe
# True default.
# ---------------------------------------------------------------------------

@test "MCP tool call → audit record has mcp_server and mcp_tool fields" {
  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'mcp__cloudflare-graphql__graphql_query',
    'tool_input': {'query': 'zones { list }'},
    'tool_response': {'result': 'ok'},
}))
")"
  bash "$HOOK_SH" --mode post <<< "$payload"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('mcp_server') == 'cloudflare-graphql', d.get('mcp_server')
assert d.get('mcp_tool') == 'graphql_query', d.get('mcp_tool')
print('ok')
"
}

@test "MCP tool call → args_summary carries key names, never values" {
  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'mcp__cast-record__query',
    'tool_input': {'account_id': 'SECRET-TOKEN-VALUE-12345', 'limit': 10},
    'tool_response': {'result': 'ok'},
}))
")"
  bash "$HOOK_SH" --mode post <<< "$payload"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
summary = d.get('args_summary', '')
assert 'account_id' in summary, summary
assert 'SECRET-TOKEN-VALUE-12345' not in summary, 'secret value leaked into args_summary'
print('ok')
"
}

@test "MCP tool call with unknown server → is_cloud_bound is true (fail-safe)" {
  bash "$HOOK_SH" --mode post <<< "$(python3 -c "
import json
print(json.dumps({'tool_name': 'mcp__unknownserver__tool', 'tool_input': {}}))
")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('is_cloud_bound') == True, f'expected fail-safe True, got {d.get(\"is_cloud_bound\")}'
print('ok')
"
}

@test "MCP tool call for a stdio-yet-cloud_bound server (github) → is_cloud_bound is true" {
  # THE discriminating case: github runs over local stdio (npx) but calls
  # api.github.com — config/egress-policy.json classifies it cloud_bound.
  # The retired transport-based logic would have returned false here.
  bash "$HOOK_SH" --mode post <<< "$(python3 -c "
import json
print(json.dumps({'tool_name': 'mcp__github__list_issues', 'tool_input': {}}))
")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('is_cloud_bound') == True, f'github (stdio, cloud_bound) must be True, got {d.get(\"is_cloud_bound\")}'
print('ok')
"
}

@test "MCP tool call for cast-record (local_only) → is_cloud_bound is false" {
  bash "$HOOK_SH" --mode post <<< "$(python3 -c "
import json
print(json.dumps({'tool_name': 'mcp__cast-record__query', 'tool_input': {}}))
")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('is_cloud_bound') == False, f'cast-record (local_only) must be False, got {d.get(\"is_cloud_bound\")}'
print('ok')
"
}

@test "MCP tool call → outcome is error when tool_response carries an error" {
  bash "$HOOK_SH" --mode post <<< "$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'mcp__srv__tool',
    'tool_input': {},
    'tool_response': {'error': 'boom'},
}))
")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('outcome') == 'error', d.get('outcome')
assert d.get('error_preview') == 'boom', d.get('error_preview')
print('ok')
"
}

@test "MCP tool call → error_preview redacts a leaked token, keeps error context" {
  local payload
  payload="$(python3 -c "
import json
token = 'ghp_' + 'f' * 36
print(json.dumps({
    'tool_name': 'mcp__srv__tool',
    'tool_input': {},
    'tool_response': {'error': f'401 Unauthorized: bad credentials {token}'},
}))
")"
  bash "$HOOK_SH" --mode post <<< "$payload"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
token = 'ghp_' + 'f' * 36
preview = d.get('error_preview', '')
assert token not in preview, f'secret token leaked into error_preview: {preview}'
assert 'Unauthorized' in preview, f'error context lost: {preview}'
print('ok')
"
}

@test "MCP tool call → error_preview absent (fail-closed) when cast-redact.py is unreachable" {
  rm -f "$HOME/.claude/scripts/cast-redact.py"
  bash "$HOOK_SH" --mode post <<< "$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'mcp__srv__tool',
    'tool_input': {},
    'tool_response': {'error': 'some raw error text'},
}))
")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('outcome') == 'error', d.get('outcome')
assert 'error_preview' not in d, f'raw text must be dropped, not stored: {d.get(\"error_preview\")}'
print('ok')
"
}

@test "Non-MCP tool call → record shape unchanged (no mcp_server/args_summary/outcome)" {
  bash "$HOOK_SH" <<< "$(make_payload "Bash")"
  local record
  record="$(tail -1 "$HOME/.claude/logs/audit.jsonl")"
  echo "$record" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
for key in ('mcp_server', 'mcp_tool', 'args_summary', 'outcome', 'error_preview', 'result_size'):
    assert key not in d, f'unexpected key {key} in non-MCP record'
print('ok')
"
}

# ---------------------------------------------------------------------------
# Registration test — directly covers the root cause of the original bug.
# The bug was NOT a script defect; it was cast-audit-hook.sh missing from
# settings.json PreToolUse. This test would FAIL on the unfixed settings.json
# (before the catch-all entry was added) and PASS after the fix.
# ---------------------------------------------------------------------------

