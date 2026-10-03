#!/usr/bin/env bats
# Regression tests for cast-db-drop-status-check.py — removes the legacy
# agent_runs.status CHECK that rejected real telemetry values ('abandoned',
# 'fallback','unknown'), preserving all columns, data, the FK, and indexes.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_DIR/scripts/cast-db-drop-status-check.py"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  export TEST_DB="$HOME/test-drop-check.db"  # under the isolated temp HOME, never /tmp
  # A realistic legacy agent_runs WITH the status CHECK, a FK, organic columns,
  # data, and a custom index.
  sqlite3 "$TEST_DB" "
    CREATE TABLE sessions (id TEXT PRIMARY KEY, project TEXT);
    CREATE TABLE agent_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT REFERENCES sessions(id),
      agent TEXT NOT NULL,
      status TEXT CHECK (status IN ('DONE','DONE_WITH_CONCERNS','BLOCKED','NEEDS_CONTEXT','running','failed')),
      project TEXT,
      abandoned_at TIMESTAMP
    );
    CREATE INDEX idx_ar_status ON agent_runs(status);
    INSERT INTO agent_runs (agent, status, project) VALUES ('a','DONE','cast'),('b','running','cast'),('c','BLOCKED','cast');
  "
}

teardown() {
  # A holder left over from a failed lock-contention test must not outlive it.
  if [ -n "${HOLDER_PID:-}" ]; then kill "$HOLDER_PID" 2>/dev/null || true; fi
  rm -f "$TEST_DB"
  teardown_temp_home
}

@test "helper removes the status CHECK and preserves row count" {
  run sqlite3 "$TEST_DB" "SELECT sql FROM sqlite_master WHERE name='agent_runs';"
  assert_output --partial "CHECK (status"

  run python3 "$HELPER" "$TEST_DB"
  assert_success

  run sqlite3 "$TEST_DB" "SELECT sql FROM sqlite_master WHERE name='agent_runs';"
  refute_output --partial "CHECK (status"

  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;"
  assert_output "3"
}

@test "previously-rejected status values become insertable after removal" {
  # Precondition: 'abandoned' is rejected while the CHECK exists.
  run sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent,status) VALUES ('x','abandoned');"
  assert_failure

  python3 "$HELPER" "$TEST_DB"

  run sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent,status) VALUES ('x','abandoned'),('y','fallback'),('z','unknown');"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE status IN ('abandoned','fallback','unknown');"
  assert_output "3"
}

@test "helper preserves indexes and the foreign key" {
  python3 "$HELPER" "$TEST_DB"

  run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_ar_status';"
  assert_output "idx_ar_status"

  run sqlite3 "$TEST_DB" "SELECT sql FROM sqlite_master WHERE name='agent_runs';"
  assert_output --partial "REFERENCES sessions(id)"
}

@test "helper preserves organic columns (column count unchanged)" {
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM pragma_table_info('agent_runs');"
  local before="$output"
  python3 "$HELPER" "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM pragma_table_info('agent_runs');"
  assert_output "$before"
  # abandoned_at organic column still present
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name='abandoned_at';"
  assert_output "1"
}

@test "helper is idempotent — second run is a clean no-op" {
  python3 "$HELPER" "$TEST_DB"
  run python3 "$HELPER" "$TEST_DB"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;"
  assert_output "3"
}

@test "helper is a no-op on a table that never had the CHECK" {
  sqlite3 "$TEST_DB" "DROP TABLE agent_runs; CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, agent TEXT, status TEXT);"
  run python3 "$HELPER" "$TEST_DB"
  assert_success
}

@test "helper exits 0 when the DB does not exist" {
  run python3 "$HELPER" "$HOME/nonexistent-drop-check.db"
  assert_success
}

@test "data integrity holds after recreation" {
  python3 "$HELPER" "$TEST_DB"
  run sqlite3 "$TEST_DB" "PRAGMA integrity_check;"
  assert_output "ok"
}

# --- Audit B-3 L1: the schema/row-count reads must happen INSIDE the write
# transaction (BEGIN IMMEDIATE). Reading before BEGIN let a concurrent writer change
# the columns between the read and the table swap, silently dropping that column's
# data. The no-op fast path must stay lock-free so a routine init never takes a
# write lock.

# Take the RESERVED (write) lock in a background process, signal readiness, hold it
# until $HOME/release exists, then add + backfill a column and commit. `3>&-` keeps
# the background process off bats' TAP pipe (an inherited fd 3 can freeze the suite).
_hold_write_lock_then_add_column() {
  python3 - "$TEST_DB" "$HOME/ready" "$HOME/release" 3>&- <<'PY' &
import os, sqlite3, sys, time
db, ready, release = sys.argv[1:4]
c = sqlite3.connect(db, timeout=10, isolation_level=None)
c.execute("BEGIN IMMEDIATE")
open(ready, "w").close()
for _ in range(400):  # bounded: gives up after ~20s so a failed test cannot hang
    if os.path.exists(release):
        break
    time.sleep(0.05)
c.execute("ALTER TABLE agent_runs ADD COLUMN late_col TEXT")
c.execute("UPDATE agent_runs SET late_col='x'")
c.execute("COMMIT")
PY
  HOLDER_PID=$!
  local _
  for _ in $(seq 1 100); do
    [ -f "$HOME/ready" ] && return 0
    sleep 0.05
  done
  return 1
}

@test "L1 race: a column added by a concurrent writer is preserved by the migration" {
  _hold_write_lock_then_add_column
  python3 "$HELPER" "$TEST_DB" >"$HOME/helper.out" 2>&1 3>&- &
  local helper_pid=$!
  # Give the helper time to reach the lock wait (python start-up is ~50ms; 2s is
  # generous). If it were released before it read anything, the pre-fix helper would
  # also pass - so this wait is what makes the test discriminate stale vs fresh reads.
  sleep 2
  kill -0 "$helper_pid" # still running => genuinely blocked behind the held lock
  touch "$HOME/release"
  local rc=0
  wait "$helper_pid" || rc=$?
  wait "$HOLDER_PID"
  [ "$rc" -eq 0 ]
  # late_col (added mid-migration) must survive the table rebuild, data included.
  run sqlite3 "$TEST_DB" "SELECT group_concat(late_col) FROM agent_runs;"
  assert_success
  assert_output "x,x,x"
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='agent_runs' AND sql LIKE '%CHECK%';"
  assert_output "0"
}

@test "L1 fast path: an already-clean DB returns 0 without waiting on a held write lock" {
  sqlite3 "$TEST_DB" "DROP TABLE agent_runs; CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, agent TEXT, status TEXT);"
  _hold_write_lock_then_add_column
  local t0=$SECONDS
  run python3 "$HELPER" "$TEST_DB"
  local dt=$((SECONDS - t0))
  touch "$HOME/release"
  wait "$HOLDER_PID"
  assert_success
  [ "$dt" -lt 5 ] # busy timeout is 10s: waiting on the lock would take >=10s
}
