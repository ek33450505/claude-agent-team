#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATION_FILE="$REPO_DIR/migrations/012-routines.sql"
ROUTINES_SCRIPT="$REPO_DIR/scripts/cast-db-routines.py"
CAST_BIN="$REPO_DIR/bin/cast"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/logs"

  export TEST_DB="$BATS_TEST_TMPDIR/test-routines-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------

@test "012-routines.sql migration is idempotent" {
  # Apply migration once
  run sqlite3 "$TEST_DB" < "$MIGRATION_FILE"
  assert_success

  # Apply migration a second time — must not error
  run sqlite3 "$TEST_DB" < "$MIGRATION_FILE"
  assert_success
}

@test "cast routines list exits 0 with empty DB" {
  # Apply schema so the table exists
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  run python3 "$ROUTINES_SCRIPT" list
  assert_success
}

@test "cast routines status exits 0 with empty DB" {
  # Apply schema so the table exists
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  run python3 "$ROUTINES_SCRIPT" status
  assert_success
}
