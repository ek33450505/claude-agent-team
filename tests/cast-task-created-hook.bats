#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-task-created-hook.sh"

make_payload() {
  local task_id="${1:-task-abc-123}"
  local task_subject="${2:-Run background analysis}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'TaskCreated',
    'task_id': sys.argv[1],
    'task_subject': sys.argv[2],
    'session_id': 'test-session-456',
    'cwd': '/tmp/test-project',
}))
" "$task_id" "$task_subject"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/cast/events"
  unset CLAUDE_SUBPROCESS
  export CAST_DB_PATH="$HOME/test-cast.db"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. Exit 0 on valid payload
# ---------------------------------------------------------------------------

@test "valid task_created payload → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 2. Exit 0 on empty input
# ---------------------------------------------------------------------------

@test "empty input → exits 0 (graceful no-op)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

# ---------------------------------------------------------------------------
# 3. Writes event file to cast/events/
# ---------------------------------------------------------------------------

@test "valid payload → writes event file to cast/events/" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*task-created.json" | wc -l)
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 4. Event file contains correct fields
# ---------------------------------------------------------------------------

@test "event file has type=task_created and correct task_id" {
  bash "$HOOK_SH" <<< "$(make_payload "task-xyz-789" "My test task")"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*task-created.json" | head -1)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('type') == 'task_created', f'type={d.get(\"type\")}'
assert d.get('task_id') == 'task-xyz-789', f'task_id={d.get(\"task_id\")}'
assert d.get('task_subject') == 'My test task', f'task_subject={d.get(\"task_subject\")}'
print('ok')
" "$event_file"
}

# ---------------------------------------------------------------------------
# 5. Handles payload with no task_subject (uses task_description fallback)
# ---------------------------------------------------------------------------

@test "payload with task_description fallback → uses it as task_subject" {
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'TaskCreated',
    'task_id': 'task-fallback',
    'task_description': 'Fallback description text',
    'session_id': 'sess',
    'cwd': '/tmp',
}))
")
  bash "$HOOK_SH" <<< "$payload"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*task-created.json" | head -1)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('task_subject') == 'Fallback description text', f'got: {d.get(\"task_subject\")}'
print('ok')
" "$event_file"
}

# ---------------------------------------------------------------------------
# 6. Graceful when cast.db does not exist
# ---------------------------------------------------------------------------

@test "missing cast.db → exits 0 without error" {
  export CAST_DB_PATH="$HOME/nonexistent.db"
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 8. task_queue INSERT uses status='pending' (not 'running')
# ---------------------------------------------------------------------------

@test "hook inserts task_queue row with status='pending'" {
  # Seed a minimal cast.db with the task_queue table
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
conn.execute('''
  CREATE TABLE IF NOT EXISTS task_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT, project TEXT, project_root TEXT,
    agent TEXT, task TEXT, status TEXT,
    priority INTEGER DEFAULT 5, retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3, claimed_at TEXT, completed_at TEXT
  )
''')
conn.commit()
conn.close()
"
  bash "$HOOK_SH" <<< "$(make_payload "task-pending-check" "Pending status test")"
  python3 -c "
import sqlite3, os, sys
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
rows = conn.execute(\"SELECT status FROM task_queue WHERE task='Pending status test'\").fetchall()
conn.close()
assert rows, 'no row inserted'
status = rows[0][0]
assert status == 'pending', f'expected pending, got {status!r}'
print('ok: status=' + status)
"
}
