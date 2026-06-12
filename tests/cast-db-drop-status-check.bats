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
  export TEST_DB="/tmp/test-drop-check-$$.db"
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
  run python3 "$HELPER" "/tmp/nonexistent-drop-check-$$.db"
  assert_success
}

@test "data integrity holds after recreation" {
  python3 "$HELPER" "$TEST_DB"
  run sqlite3 "$TEST_DB" "PRAGMA integrity_check;"
  assert_output "ok"
}
