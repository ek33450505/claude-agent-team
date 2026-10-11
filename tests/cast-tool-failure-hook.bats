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
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/cast"
  unset CLAUDE_SUBPROCESS
  # Create a real cast.db with the tool_call_failures schema for DB tests
  python3 -c "
import sqlite3, os
db = os.path.join(os.environ['HOME'], '.claude', 'cast.db')
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS tool_call_failures (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT, session_id TEXT, tool_name TEXT,
  error TEXT, project TEXT, data TEXT
)''')
con.commit(); con.close()
"
}

teardown() {
  teardown_temp_home
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

@test "valid payload → cast.db row has correct fields, no tool-failures.jsonl" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-fail-1" "Read" "src/missing.ts" "File not found")"
  python3 -c "
import sqlite3, os
db = os.path.join(os.environ['HOME'], '.claude', 'cast.db')
con = sqlite3.connect(db)
row = con.execute('SELECT tool_name, error FROM tool_call_failures WHERE session_id=?', ('sess-fail-1',)).fetchone()
con.close()
assert row is not None, 'no row written'
assert row == ('Read', 'File not found'), f'row={row}'

print('ok')
"
  [ ! -e "$HOME/.claude/cast/tool-failures.jsonl" ]
}

# ---------------------------------------------------------------------------
# 3. Long error message → error_preview truncated to 200 chars
# ---------------------------------------------------------------------------

@test "error longer than 200 chars → db error capped at 200" {
  local long_error
  long_error=$(python3 -c "print('E' * 400)")
  bash "$HOOK_SH" <<< "$(make_payload "sess-longerr" "Bash" "ls" "$long_error")"
  python3 -c "
import sqlite3, os
db = os.path.join(os.environ['HOME'], '.claude', 'cast.db')
con = sqlite3.connect(db)
row = con.execute('SELECT error FROM tool_call_failures WHERE session_id=?', ('sess-longerr',)).fetchone()
con.close()
assert row is not None and len(row[0]) == 200, f'row={row and len(row[0])}'

print('ok')
"
}

# ---------------------------------------------------------------------------
# 5. Sink removed: no tool-failures.jsonl is created
# ---------------------------------------------------------------------------

@test "tool_input longer than 100 chars → exits 0, no tool-failures.jsonl" {
  local long_input
  long_input=$(python3 -c "print('I' * 300)")
  run bash "$HOOK_SH" <<< "$(make_payload "sess-longinput" "Bash" "$long_input" "error")"
  assert_success
  [ ! -e "$HOME/.claude/cast/tool-failures.jsonl" ]
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
# 8. Multiple failures → one DB row each
# ---------------------------------------------------------------------------

@test "two failures → two cast.db rows, no tool-failures.jsonl" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-a" "Bash" "cmd1" "err1")"
  bash "$HOOK_SH" <<< "$(make_payload "sess-b" "Read" "file" "err2")"
  run python3 -c "
import sqlite3, os
con = sqlite3.connect(os.path.join(os.environ['HOME'], '.claude', 'cast.db'))
print(con.execute('SELECT COUNT(*) FROM tool_call_failures').fetchone()[0])
"
  assert_output "2"
  [ ! -e "$HOME/.claude/cast/tool-failures.jsonl" ]
}

# ---------------------------------------------------------------------------
# 9. Error with quotes and special chars → handled safely
# ---------------------------------------------------------------------------

@test "error with special chars → exits 0 and writes DB row" {
  local special_error="Failed: 'quote' and \"dquote\" and \$var and {json}"
  run bash "$HOOK_SH" <<< "$(make_payload "sess-special" "Write" "/tmp/f" "$special_error")"
  assert_success
  run python3 -c "
import sqlite3, os
con = sqlite3.connect(os.path.join(os.environ['HOME'], '.claude', 'cast.db'))
print(con.execute('SELECT COUNT(*) FROM tool_call_failures WHERE session_id=?', ('sess-special',)).fetchone()[0])
"
  assert_output "1"
}

# ---------------------------------------------------------------------------
# 10. DB write: tool_call_failures row has tool_name and project populated
# ---------------------------------------------------------------------------

@test "DB write: tool_call_failures row includes tool_name and project for tool_failure" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-db-tf-1" "Bash" "ls /missing" "No such file")"
  python3 -c "
import sqlite3, os
db = os.path.join(os.environ['HOME'], '.claude', 'cast.db')
con = sqlite3.connect(db)
row = con.execute(
    'SELECT tool_name, project FROM tool_call_failures WHERE session_id=?',
    ('sess-db-tf-1',)
).fetchone()
con.close()
assert row is not None, 'no row written to tool_call_failures'
tool_name, project = row
assert tool_name == 'Bash',                                       f'tool_name={tool_name}'
assert project is not None and len(project) > 0, f'project is NULL or empty'
print('ok')
"
}
