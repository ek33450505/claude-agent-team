#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-teammate-idle-hook.sh"

make_payload() {
  local session_id="${1:-test-session-abc}"
  local agent_id="${2:-agent_test_001}"
  local agent_type="${3:-code-reviewer}"
  local teammate="${4:-code-reviewer}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'TeammateIdle',
    'session_id': sys.argv[1],
    'agent_id': sys.argv[2],
    'agent_type': sys.argv[3],
    'teammate_name': sys.argv[4],
    'cwd': '/tmp/test-project',
}))
" "$session_id" "$agent_id" "$agent_type" "$teammate"
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

@test "valid TeammateIdle payload → exits 0" {
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
# 3. Writes *teammate-idle.json event file
# ---------------------------------------------------------------------------

@test "valid payload → writes teammate-idle.json event file" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*teammate-idle.json" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 4. Event file has type=teammate_idle and correct agent_id
# ---------------------------------------------------------------------------

@test "event file has type=teammate_idle and correct agent_id" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-1234" "agent_xyz" "debugger" "debugger")"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*teammate-idle.json" | head -1)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('type') == 'teammate_idle', f'type={d.get(\"type\")}'
assert d.get('agent_id') == 'agent_xyz', f'agent_id={d.get(\"agent_id\")}'
print('ok')
" "$event_file"
}

# ---------------------------------------------------------------------------
# 5. Missing cast.db → exits 0 without error
# ---------------------------------------------------------------------------

@test "missing cast.db → exits 0 without error" {
  export CAST_DB_PATH="$HOME/nonexistent.db"
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 6. Seeded DB → teammate_runs row has status=idle, agent_role, agent_def, swarm_id
# ---------------------------------------------------------------------------

@test "seeded DB → teammate_runs row has status=idle, agent_role=teammate_name, agent_def=agent_type, swarm_id=team_id" {
  seed_db
  # New contract (B): row keyed by {team_id}-{teammate}, not agent_id.
  # session_id="test-session-ab" → [:8]="test-ses" → team_id="session-test-ses"; teammate="commit"
  # → row id = "session-test-ses-commit"
  bash "$HOOK_SH" <<< "$(make_payload "test-session-ab" "agent_role_test" "commit" "commit")"
  python3 -c "
import sqlite3, os, sys
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
rows = conn.execute(\"SELECT status, agent_role, agent_def, swarm_id FROM teammate_runs WHERE id='session-test-ses-commit'\").fetchall()
conn.close()
assert rows, 'no teammate_runs row inserted'
status, agent_role, agent_def, swarm_id = rows[0]
assert status == 'idle', f'expected idle, got {status!r}'
assert agent_role == 'commit', f'expected commit, got {agent_role!r}'
assert agent_def == 'commit', f'expected commit (agent_type), got {agent_def!r}'
assert swarm_id == 'session-test-ses', f'expected session-test-ses, got {swarm_id!r}'
print('ok: status=%s role=%s def=%s swarm=%s' % (status, agent_role, agent_def, swarm_id))
"
}

# ---------------------------------------------------------------------------
# 7. swarm_sessions row created with notes containing schema_version
# ---------------------------------------------------------------------------

@test "seeded DB → swarm_sessions row created with notes containing schema_version" {
  seed_db
  bash "$HOOK_SH" <<< "$(make_payload "test-session-ss" "agent_ss" "code-writer" "code-writer")"
  python3 -c "
import sqlite3, os, json
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
rows = conn.execute(\"SELECT notes FROM swarm_sessions WHERE id='session-test-ses'\").fetchall()
conn.close()
assert rows, 'no swarm_sessions row created'
notes = json.loads(rows[0][0])
assert notes.get('schema_version') == 1, f'schema_version missing: {notes}'
print('ok: schema_version=%d' % notes['schema_version'])
"
}

# ---------------------------------------------------------------------------
# 8. Idempotent — firing twice yields exactly ONE teammate_runs row for that agent_id
# ---------------------------------------------------------------------------

@test "idempotent — firing twice yields exactly one teammate_runs row for teammate_name" {
  seed_db
  # New contract (B): row keyed by {team_id}-{teammate}.
  # session_id="test-session-id" → [:8]="test-ses" → team_id="session-test-ses"; teammate="bash-specialist"
  # → row id = "session-test-ses-bash-specialist"
  local payload
  payload="$(make_payload "test-session-id" "agent_idem" "bash-specialist" "bash-specialist")"
  bash "$HOOK_SH" <<< "$payload"
  bash "$HOOK_SH" <<< "$payload"
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
count = conn.execute(\"SELECT COUNT(*) FROM teammate_runs WHERE id='session-test-ses-bash-specialist'\").fetchone()[0]
conn.close()
assert count == 1, f'expected 1 row, got {count}'
print('ok: exactly 1 row after 2 fires')
"
}

# ---------------------------------------------------------------------------
# 9. Empty teammate_name → no teammate_runs row (guard contract B)
# ---------------------------------------------------------------------------

@test "empty teammate_name → no teammate_runs row inserted" {
  seed_db
  # Native payloads with empty teammate_name must be silently skipped.
  # Guard contract (B): `if has("teammate_runs") and teammate and team_id:`
  # Note: make_payload uses ${4:-default} so passing "" triggers the default;
  # build the payload directly to guarantee empty teammate_name.
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'TeammateIdle',
    'session_id': 'test-session-empty',
    'agent_id': 'agent_empty',
    'agent_type': 'code-writer',
    'teammate_name': '',
    'cwd': '/tmp/test-project',
}))
")
  bash "$HOOK_SH" <<< "$payload"
  python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
count = conn.execute('SELECT COUNT(*) FROM teammate_runs').fetchone()[0]
conn.close()
assert count == 0, f'expected 0 rows for empty teammate, got {count}'
print('ok: no row for empty teammate_name')
"
}
