#!/usr/bin/env bats
# queue_status.bats — Tests for cast queue cancel / retry (Phase 9.75b)
#
# Coverage:
#   - cast queue cancel <id> sets status to 'cancelled' (not 'failed')
#   - cast queue retry <id> resets retry_count to 0

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Insert a task into task_queue; returns the new row id via stdout.
_insert_task() {
  local db="$1"
  local status="${2:-pending}"
  local retry_count="${3:-0}"
  python3 - "$db" "$status" "$retry_count" <<'PYEOF'
import sys, sqlite3
db_path, status, retry_count = sys.argv[1], sys.argv[2], int(sys.argv[3])
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(
    """INSERT INTO task_queue
       (created_at, agent, task, status, retry_count)
       VALUES (datetime('now'), 'test-agent', 'test task', ?, ?)""",
    (status, retry_count)
)
conn.commit()
print(cur.lastrowid)
conn.close()
PYEOF
}

# Read a single field from a task_queue row.
_task_field() {
  local db="$1"
  local task_id="$2"
  local field="$3"
  python3 - "$db" "$task_id" "$field" <<'PYEOF'
import sys, sqlite3
db_path, task_id, field = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(f"SELECT {field} FROM task_queue WHERE id=?", (task_id,))
row = cur.fetchone()
conn.close()
print(row[0] if row else "")
PYEOF
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/config" "$HOME/.claude/logs"

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  # Minimal config so bin/cast doesn't complain
  cat > "$HOME/.claude/config/cast-cli.json" <<'JSON'
{
  "db_path": "~/.claude/cast-test.db",
  "ollama_url": "http://localhost:19999",
  "redact_pii": false,
  "default_model": "auto",
  "log_dir": "~/.claude/logs"
}
JSON
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# T1 — cast queue cancel sets status to 'cancelled', not 'failed'
# ---------------------------------------------------------------------------

@test "queue cancel: sets status to 'cancelled'" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "pending" 0)"

  run bash "$CAST_CLI" queue cancel "$task_id"
  assert_success

  local status
  status="$(_task_field "$CAST_DB_PATH" "$task_id" "status")"
  [ "$status" = "cancelled" ]
}

@test "queue cancel: status is NOT 'failed' after cancellation" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "pending" 0)"

  bash "$CAST_CLI" queue cancel "$task_id"

  local status
  status="$(_task_field "$CAST_DB_PATH" "$task_id" "status")"
  [ "$status" != "failed" ]
}

@test "queue cancel: prints confirmation message" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "pending" 0)"

  run bash "$CAST_CLI" queue cancel "$task_id"
  assert_success
  assert_output --partial "cancelled"
}

@test "queue cancel: only affects pending tasks (ignores non-pending)" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "done" 0)"

  run bash "$CAST_CLI" queue cancel "$task_id"
  # Exits 0 with a warning — task was not pending so no rows updated
  assert_success

  local status
  status="$(_task_field "$CAST_DB_PATH" "$task_id" "status")"
  # Status should remain 'done', not 'cancelled'
  [ "$status" = "done" ]
}

@test "queue cancel: warns gracefully for a non-existent task id" {
  run bash "$CAST_CLI" queue cancel 99999
  assert_success
  assert_output --partial "not found"
}

@test "queue cancel: missing task-id argument prints usage error" {
  run bash "$CAST_CLI" queue cancel
  assert_failure
  assert_output --partial "Usage: cast queue cancel"
}

@test "queue cancel: second cancel on same task is idempotent (exits 0)" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "pending" 0)"

  bash "$CAST_CLI" queue cancel "$task_id"
  # Second call: task is no longer 'pending', should warn but not crash
  run bash "$CAST_CLI" queue cancel "$task_id"
  assert_success
}

# ---------------------------------------------------------------------------
# T2 — cast queue retry resets retry_count to 0
# ---------------------------------------------------------------------------

@test "queue retry: resets retry_count to 0" {
  # Insert a task with retry_count=3 (simulating exhausted retries)
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "failed" 3)"

  run bash "$CAST_CLI" queue retry "$task_id"
  assert_success

  local retry_count
  retry_count="$(_task_field "$CAST_DB_PATH" "$task_id" "retry_count")"
  [ "$retry_count" = "0" ]
}

@test "queue retry: sets status back to 'pending'" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "failed" 2)"

  bash "$CAST_CLI" queue retry "$task_id"

  local status
  status="$(_task_field "$CAST_DB_PATH" "$task_id" "status")"
  [ "$status" = "pending" ]
}

@test "queue retry: clears claimed_at field" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "failed" 1)"

  # Manually set claimed_at to simulate a mid-flight failure
  python3 - "$CAST_DB_PATH" "$task_id" <<'PYEOF'
import sys, sqlite3
db_path, task_id = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
conn.execute("UPDATE task_queue SET claimed_at=datetime('now'), claimed_by_session='old-session' WHERE id=?", (task_id,))
conn.commit()
conn.close()
PYEOF

  bash "$CAST_CLI" queue retry "$task_id"

  local claimed_at
  claimed_at="$(_task_field "$CAST_DB_PATH" "$task_id" "claimed_at")"
  [ -z "$claimed_at" ] || [ "$claimed_at" = "None" ] || [ "$claimed_at" = "" ]
}

@test "queue retry: prints confirmation message" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "failed" 2)"

  run bash "$CAST_CLI" queue retry "$task_id"
  assert_success
  assert_output --partial "pending"
}

@test "queue retry: warns gracefully for a non-existent task id" {
  run bash "$CAST_CLI" queue retry 99999
  assert_success
  assert_output --partial "not found"
}

@test "queue retry: missing task-id argument prints usage error" {
  run bash "$CAST_CLI" queue retry
  assert_failure
  assert_output --partial "Usage: cast queue retry"
}

@test "queue retry: retry_count starts at 0 for a task already at 0" {
  local task_id
  task_id="$(_insert_task "$CAST_DB_PATH" "pending" 0)"

  bash "$CAST_CLI" queue retry "$task_id"

  local retry_count
  retry_count="$(_task_field "$CAST_DB_PATH" "$task_id" "retry_count")"
  [ "$retry_count" = "0" ]
}

# ---------------------------------------------------------------------------
# T3 — verify queue cancel and retry are independent (no cross-contamination)
# ---------------------------------------------------------------------------

@test "queue cancel and retry: cancelling task A does not affect task B" {
  local task_a task_b
  task_a="$(_insert_task "$CAST_DB_PATH" "pending" 0)"
  task_b="$(_insert_task "$CAST_DB_PATH" "pending" 0)"

  bash "$CAST_CLI" queue cancel "$task_a"

  local status_b
  status_b="$(_task_field "$CAST_DB_PATH" "$task_b" "status")"
  [ "$status_b" = "pending" ]
}

@test "queue retry: retrying task A does not affect retry_count of task B" {
  local task_a task_b
  task_a="$(_insert_task "$CAST_DB_PATH" "failed" 5)"
  task_b="$(_insert_task "$CAST_DB_PATH" "failed" 7)"

  bash "$CAST_CLI" queue retry "$task_a"

  local retry_b
  retry_b="$(_task_field "$CAST_DB_PATH" "$task_b" "retry_count")"
  [ "$retry_b" = "7" ]
}
