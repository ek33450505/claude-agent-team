#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-tool-failure-hook.sh"

make_payload() {
  local session_id="${1:-test-session-001}"
  local tool_name="${2:-Bash}"
  local tool_input="${3:-ls /nonexistent}"
  local error="${4:-No such file or directory}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'PostToolUseFailure',
    'session_id':  sys.argv[1],
    'tool_name':   sys.argv[2],
    'tool_input':  sys.argv[3],
    'error':       sys.argv[4],
}))
" "$session_id" "$tool_name" "$tool_input" "$error"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast"
  unset CLAUDE_SUBPROCESS
  # Create a real cast.db with the routing_events schema for DB tests
  python3 -c "
import sqlite3, os
db = os.path.join(os.environ['HOME'], '.claude', 'cast.db')
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS routing_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT, timestamp TEXT, prompt_preview TEXT,
  action TEXT, matched_route TEXT, match_type TEXT,
  pattern TEXT, confidence TEXT, project TEXT,
  event_type TEXT, data TEXT
)''')
con.commit(); con.close()
"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Happy path: valid JSON → exits 0
# ---------------------------------------------------------------------------

@test "valid PostToolUseFailure payload → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 2. Happy path: log entry created with correct fields
# ---------------------------------------------------------------------------

@test "valid payload → appends to tool-failures.jsonl with correct fields" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-fail-1" "Read" "src/missing.ts" "File not found")"
  [ -f "$HOME/.claude/cast/tool-failures.jsonl" ]
  python3 -c "
import json
with open('$HOME/.claude/cast/tool-failures.jsonl') as f:
    d = json.loads(f.readline().strip())
assert d.get('session_id')    == 'sess-fail-1',    f'session_id={d.get(\"session_id\")}'
assert d.get('tool_name')     == 'Read',           f'tool_name={d.get(\"tool_name\")}'
assert d.get('error_preview') == 'File not found', f'error_preview={d.get(\"error_preview\")}'
assert d.get('input_preview') == 'src/missing.ts', f'input_preview={d.get(\"input_preview\")}'
assert 'timestamp' in d, 'missing timestamp'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 3. CLAUDE_SUBPROCESS guard
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 → exits 0 and writes nothing" {
  CLAUDE_SUBPROCESS=1 run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
  [ ! -f "$HOME/.claude/cast/tool-failures.jsonl" ]
}

# ---------------------------------------------------------------------------
# 4. Long error message → error_preview truncated to 200 chars
# ---------------------------------------------------------------------------

@test "error longer than 200 chars → error_preview capped at 200" {
  local long_error
  long_error=$(python3 -c "print('E' * 400)")
  bash "$HOOK_SH" <<< "$(make_payload "sess-longerr" "Bash" "ls" "$long_error")"
  python3 -c "
import json
with open('$HOME/.claude/cast/tool-failures.jsonl') as f:
    d = json.loads(f.readline().strip())
preview_len = len(d.get('error_preview', ''))
assert preview_len == 200, f'expected 200, got {preview_len}'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 5. Long tool_input → input_preview truncated to 100 chars
# ---------------------------------------------------------------------------

@test "tool_input longer than 100 chars → input_preview capped at 100" {
  local long_input
  long_input=$(python3 -c "print('I' * 300)")
  bash "$HOOK_SH" <<< "$(make_payload "sess-longinput" "Bash" "$long_input" "error")"
  python3 -c "
import json
with open('$HOME/.claude/cast/tool-failures.jsonl') as f:
    d = json.loads(f.readline().strip())
input_len = len(d.get('input_preview', ''))
assert input_len == 100, f'expected 100, got {input_len}'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 6. Invalid JSON → exits 0 (never crash)
# ---------------------------------------------------------------------------

@test "invalid JSON input → exits 0 gracefully" {
  run bash "$HOOK_SH" <<< "not json at all"
  assert_success
}

# ---------------------------------------------------------------------------
# 7. Empty input → exits 0
# ---------------------------------------------------------------------------

@test "empty input → exits 0" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

# ---------------------------------------------------------------------------
# 8. Multiple failures → appends, not overwrites
# ---------------------------------------------------------------------------

@test "two failures → two lines in jsonl" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-a" "Bash" "cmd1" "err1")"
  bash "$HOOK_SH" <<< "$(make_payload "sess-b" "Read" "file" "err2")"
  local lines
  lines=$(wc -l < "$HOME/.claude/cast/tool-failures.jsonl")
  [ "$lines" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 9. Error with quotes and special chars → handled safely
# ---------------------------------------------------------------------------

@test "error with special chars → exits 0 and logs" {
  local special_error="Failed: 'quote' and \"dquote\" and \$var and {json}"
  run bash "$HOOK_SH" <<< "$(make_payload "sess-special" "Write" "/tmp/f" "$special_error")"
  assert_success
  [ -f "$HOME/.claude/cast/tool-failures.jsonl" ]
}

# ---------------------------------------------------------------------------
# 10. DB regression: routing_events row has action and project populated
#     (regression for bug where only event_type was written — action and
#      project were NULL)
# ---------------------------------------------------------------------------

@test "DB write: routing_events row includes action and project for tool_failure" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-db-tf-1" "Bash" "ls /missing" "No such file")"
  python3 -c "
import sqlite3, os
db = os.path.join(os.environ['HOME'], '.claude', 'cast.db')
con = sqlite3.connect(db)
row = con.execute(
    'SELECT event_type, action, project FROM routing_events WHERE session_id=?',
    ('sess-db-tf-1',)
).fetchone()
con.close()
assert row is not None, 'no row written to routing_events'
event_type, action, project = row
assert event_type == 'tool_failure',  f'event_type={event_type}'
assert action     == 'tool_failure',  f'action is NULL or wrong: {action}'
assert project is not None and len(project) > 0, f'project is NULL or empty'
print('ok')
"
}
