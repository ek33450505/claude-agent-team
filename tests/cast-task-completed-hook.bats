#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-task-completed-hook.sh"

make_payload() {
  local session_id="${1:-test-session-abc}"
  local task_id="${2:-task_test_001}"
  local task_subject="${3:-Test task subject}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'TaskCompleted',
    'session_id': sys.argv[1],
    'task_id': sys.argv[2],
    'task_subject': sys.argv[3],
    'cwd': '/tmp/test-project',
}))
" "$session_id" "$task_id" "$task_subject"
}

seed_db() {
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
conn.execute('''
  CREATE TABLE IF NOT EXISTS swarm_sessions (
    id           TEXT PRIMARY KEY,
    team_name    TEXT NOT NULL,
    config_path  TEXT,
    started_at   TEXT,
    ended_at     TEXT,
    status       TEXT DEFAULT 'running',
    session_id   TEXT,
    project      TEXT,
    notes        TEXT
  )
''')
conn.execute('''
  CREATE TABLE IF NOT EXISTS teammate_runs (
    id           TEXT PRIMARY KEY,
    swarm_id     TEXT REFERENCES swarm_sessions(id),
    agent_role   TEXT,
    agent_def    TEXT,
    worktree     TEXT,
    task_id      TEXT,
    task_subject TEXT,
    status       TEXT DEFAULT 'idle',
    started_at   TEXT,
    ended_at     TEXT,
    tokens_in    INTEGER DEFAULT 0,
    tokens_out   INTEGER DEFAULT 0
  )
''')
conn.commit()
conn.close()
"
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

@test "valid TaskCompleted payload → exits 0" {
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
# 3. Writes *task-completed.json event file with type=task_completed and task_id
# ---------------------------------------------------------------------------

@test "valid payload → writes task-completed.json event file with correct type and task_id" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-tc-abc" "task_ev_check" "My completed task")"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*task-completed.json" | head -1)
  [ -n "$event_file" ] || { echo "No event file found"; return 1; }
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('type') == 'task_completed', f'type={d.get(\"type\")}'
assert d.get('task_id') == 'task_ev_check', f'task_id={d.get(\"task_id\")}'
print('ok')
" "$event_file"
}

# ---------------------------------------------------------------------------
# 4. Missing cast.db → exits 0 without error
# ---------------------------------------------------------------------------

@test "missing cast.db → exits 0 without error" {
  export CAST_DB_PATH="$HOME/nonexistent.db"
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 5. Seeded DB → teammate_runs row id='task-'+task_id, status=completed, task_subject set
# ---------------------------------------------------------------------------

@test "seeded DB → teammate_runs row id=task-<task_id> with status=completed and task_subject" {
  seed_db
  bash "$HOOK_SH" <<< "$(make_payload "test-session-tc" "my-task-99" "Deploy production")"
  python3 -c "
import sqlite3, os, sys
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
rows = conn.execute(\"SELECT id, status, task_subject FROM teammate_runs WHERE id='task-my-task-99'\").fetchall()
conn.close()
assert rows, 'no teammate_runs row inserted for task-my-task-99'
row_id, status, task_subject = rows[0]
assert status == 'completed', f'expected completed, got {status!r}'
assert task_subject == 'Deploy production', f'task_subject={task_subject!r}'
print('ok: id=%s status=%s subject=%s' % (row_id, status, task_subject))
"
}

# ---------------------------------------------------------------------------
# 6. swarm_sessions row created
# ---------------------------------------------------------------------------

@test "seeded DB → swarm_sessions row created" {
  seed_db
  bash "$HOOK_SH" <<< "$(make_payload "test-session-sw" "task_sw_test" "Session row test")"
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
# team_id = 'session-' + session_id[:8] = 'session-test-ses'
rows = conn.execute(\"SELECT id FROM swarm_sessions WHERE id='session-test-ses'\").fetchall()
conn.close()
assert rows, 'no swarm_sessions row created for session-test-ses'
print('ok: swarm_sessions row found for ' + rows[0][0])
"
}

# ---------------------------------------------------------------------------
# 7. task_description fallback — used when task_subject is absent
# ---------------------------------------------------------------------------

@test "payload with task_description fallback → uses it as task_subject in event file" {
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'TaskCompleted',
    'session_id': 'sess-desc-fb',
    'task_id': 'task_desc_fb',
    'task_description': 'Fallback description text',
    'cwd': '/tmp',
}))
")
  bash "$HOOK_SH" <<< "$payload"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*task-completed.json" | head -1)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('task_subject') == 'Fallback description text', f'got: {d.get(\"task_subject\")}'
print('ok')
" "$event_file"
}

# ---------------------------------------------------------------------------
# 8. Idempotent — firing twice yields exactly ONE teammate_runs row for that task_id
# ---------------------------------------------------------------------------

@test "idempotent — firing twice yields exactly one teammate_runs row for task_id" {
  seed_db
  local payload
  payload="$(make_payload "test-session-idem" "task_idem_99" "Idempotent test")"
  bash "$HOOK_SH" <<< "$payload"
  bash "$HOOK_SH" <<< "$payload"
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
count = conn.execute(\"SELECT COUNT(*) FROM teammate_runs WHERE id='task-task_idem_99'\").fetchone()[0]
conn.close()
assert count == 1, f'expected 1 row, got {count}'
print('ok: exactly 1 row after 2 fires')
"
}

# ---------------------------------------------------------------------------
# 9. payload without task_id → exits 0 and writes no teammate_runs row
# ---------------------------------------------------------------------------

@test "payload without task_id → exits 0 and writes no teammate_runs row" {
  seed_db
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'TaskCompleted',
    'session_id': 'sess-notaskid',
    'task_subject': 'No task id here',
    'cwd': '/tmp/test-project',
}))
")
  run bash "$HOOK_SH" <<< "$payload"
  assert_success
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
count = conn.execute('SELECT COUNT(*) FROM teammate_runs').fetchone()[0]
conn.close()
assert count == 0, f'expected 0 teammate_runs rows, got {count}'
print('ok: no teammate_runs row written when task_id absent')
"
}

# ---------------------------------------------------------------------------
# 10. payload with team_name → swarm_sessions keyed by team_name
# ---------------------------------------------------------------------------

@test "payload with team_name → swarm_sessions keyed by team_name" {
  seed_db
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'TaskCompleted',
    'session_id': 'sess-teamname-test',
    'task_id': 'task_teamname_001',
    'task_subject': 'Team name grouping test',
    'team_name': 'session-teamXY',
    'cwd': '/tmp/test-project',
}))
")
  bash "$HOOK_SH" <<< "$payload"
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
rows = conn.execute(\"SELECT id FROM swarm_sessions WHERE id='session-teamXY'\").fetchall()
conn.close()
assert rows, 'no swarm_sessions row with id=session-teamXY'
print('ok: swarm_sessions keyed by team_name ' + rows[0][0])
"
}
