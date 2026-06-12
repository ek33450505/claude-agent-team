#!/usr/bin/env bats
# Tests for file_writes INSERT path in cast-post-tool.py (part6_file_writes).
# Verifies that Write/Edit/MultiEdit tool calls are recorded to file_writes table.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
POST_TOOL_PY="$REPO_DIR/scripts/cast-post-tool.py"
SCRIPTS_DIR="$REPO_DIR/scripts"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"

  export TEST_DB="$BATS_TEST_TMPDIR/cast-file-writes-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Ensure scripts/ is importable as a package (cast_db lives there)
  export PYTHONPATH="$SCRIPTS_DIR"

  unset CLAUDE_SUBPROCESS
  unset CAST_AGENT_NAME
  unset CAST_AGENT_RUN_ID
  unset CLAUDE_SESSION_ID
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: build a PostToolUse JSON payload
# ---------------------------------------------------------------------------
write_fw_payload() {
  local tool_name="${1:-Write}"
  local file_path="${2:-/tmp/foo.txt}"
  local session_id="${3:-test-sid}"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': sys.argv[1],
    'tool_input': {'file_path': sys.argv[2], 'content': 'hello'},
    'tool_response': {},
    'session_id': sys.argv[3],
}))
" "$tool_name" "$file_path" "$session_id"
}

# ---------------------------------------------------------------------------
# 1. Write tool → row inserted into file_writes
# ---------------------------------------------------------------------------

@test "file_writes: Write tool inserts a row with correct tool_name and file_path" {
  local payload
  payload="$(write_fw_payload Write /tmp/testfile.py test-sid-1)"

  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM file_writes WHERE tool_name='Write';")
  [ "$count" -eq 1 ]

  local stored_path
  stored_path=$(sqlite3 "$TEST_DB" "SELECT file_path FROM file_writes WHERE tool_name='Write' LIMIT 1;")
  # file_path should be the realpath of /tmp/testfile.py
  [[ "$stored_path" == *"testfile.py"* ]]
}

# ---------------------------------------------------------------------------
# 2. Edit tool → row inserted
# ---------------------------------------------------------------------------

@test "file_writes: Edit tool inserts a row with tool_name=Edit" {
  local payload
  payload="$(write_fw_payload Edit /tmp/edit_target.ts test-sid-2)"

  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM file_writes WHERE tool_name='Edit';")
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 3. MultiEdit tool → row inserted
# ---------------------------------------------------------------------------

@test "file_writes: MultiEdit tool inserts a row with tool_name=MultiEdit" {
  local payload
  payload="$(write_fw_payload MultiEdit /tmp/multi_target.ts test-sid-3)"

  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM file_writes WHERE tool_name='MultiEdit';")
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 4. session_id is captured from payload
# ---------------------------------------------------------------------------

@test "file_writes: session_id from payload is stored correctly" {
  local payload
  payload="$(write_fw_payload Write /tmp/foo.py test-session-xyz)"

  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  local sid
  sid=$(sqlite3 "$TEST_DB" "SELECT session_id FROM file_writes WHERE tool_name='Write' LIMIT 1;")
  [ "$sid" = "test-session-xyz" ]
}

# ---------------------------------------------------------------------------
# 5. Non-Write tools (Read, Bash) → no row inserted
# ---------------------------------------------------------------------------

@test "file_writes: Read tool does NOT insert into file_writes" {
  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Read',
    'tool_input': {'file_path': '/tmp/foo.py'},
    'tool_response': {},
    'session_id': 'test-sid-read',
}))
")"

  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  # Table may not even exist yet; either way, count should be 0
  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='file_writes';" 2>/dev/null || echo "0")
  if [ "$count" -eq 1 ]; then
    local rows
    rows=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM file_writes;" 2>/dev/null || echo "0")
    [ "$rows" -eq 0 ]
  fi
}

# ---------------------------------------------------------------------------
# 6. agent_name captured from CAST_AGENT_NAME env var
# ---------------------------------------------------------------------------

@test "file_writes: CAST_AGENT_NAME env var is stored as agent_name" {
  local payload
  payload="$(write_fw_payload Write /tmp/foo.py test-sid-agent)"

  run env CAST_AGENT_NAME=code-writer python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  local agent
  agent=$(sqlite3 "$TEST_DB" "SELECT agent_name FROM file_writes WHERE tool_name='Write' LIMIT 1;")
  [ "$agent" = "code-writer" ]
}

# ---------------------------------------------------------------------------
# 7. Idempotent table creation — calling the script twice doesn't error
# ---------------------------------------------------------------------------

@test "file_writes: running twice (idempotent CREATE TABLE IF NOT EXISTS) does not error" {
  local payload
  payload="$(write_fw_payload Write /tmp/foo.py test-sid-idem)"

  # First call
  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  # Second call — table already exists
  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM file_writes;")
  [ "$count" -eq 2 ]
}
