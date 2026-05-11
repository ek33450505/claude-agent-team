#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-incidents-backfill.py"
INCIDENTS_MIGRATION="$REPO_DIR/migrations/011-incidents.sql"

setup() {
  export TEST_DB
  TEST_DB="$(mktemp /tmp/test-incidents-backfill-XXXXXX.db)"
  export CAST_DB_PATH="$TEST_DB"
  # Create the incidents table using the canonical migration SQL
  sqlite3 "$TEST_DB" < "$INCIDENTS_MIGRATION"
}

teardown() {
  rm -f "$TEST_DB"
}

@test "cast-incidents-backfill adds 17 rows on first run" {
  run python3 "$SCRIPT"
  assert_success
  assert_output --partial "17 added"
  assert_output --partial "Total rows in incidents table: 17"
}

@test "cast-incidents-backfill is idempotent (second run adds 0 rows)" {
  python3 "$SCRIPT"
  run python3 "$SCRIPT"
  assert_success
  assert_output --partial "0 added"
  assert_output --partial "17 skipped"
  assert_output --partial "Total rows in incidents table: 17"
}

@test "cast-incidents-backfill row count stays stable across two runs" {
  python3 "$SCRIPT"
  python3 "$SCRIPT"
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents;")
  [ "$count" -eq 17 ]
}

@test "cast-incidents-backfill all rows have resolution_status=fixed" {
  python3 "$SCRIPT"
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents WHERE resolution_status != 'fixed';")
  [ "$count" -eq 0 ]
}

@test "cast-incidents-backfill all rows have non-empty problem_summary" {
  python3 "$SCRIPT"
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents WHERE problem_summary IS NULL OR problem_summary = '';")
  [ "$count" -eq 0 ]
}
