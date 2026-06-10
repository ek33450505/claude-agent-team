#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATE_SCRIPT="$REPO_DIR/scripts/cast-migrate.py"
MIGRATIONS_DIR="$REPO_DIR/scripts/migrations"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude"

  export TEST_DB="$BATS_TEST_TMPDIR/test-migrate-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Schema migrations table creation
# ---------------------------------------------------------------------------

@test "cast-migrate.py: fresh DB creates schema_migrations table on first run" {
  run python3 "$MIGRATE_SCRIPT"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations';")
  [ "$count" -eq 1 ]
}

@test "cast-migrate.py: applies all NNN_*.sql files and records rows in schema_migrations" {
  run python3 "$MIGRATE_SCRIPT"
  assert_success

  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")
  # Must have at least 7 migrations (009-015 + 016-019 = 11 files minimum)
  [ "$row_count" -ge 7 ]
}

@test "cast-migrate.py: incidents table exists after migration run" {
  run python3 "$MIGRATE_SCRIPT"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='incidents';")
  [ "$count" -eq 1 ]
}

@test "cast-migrate.py: routines table exists after migration run" {
  run python3 "$MIGRATE_SCRIPT"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='routines';")
  [ "$count" -eq 1 ]
}

@test "cast-migrate.py: plan_sessions table exists after migration run" {
  run python3 "$MIGRATE_SCRIPT"
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='plan_sessions';")
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Idempotency — second run must not duplicate ledger rows or error
# ---------------------------------------------------------------------------

@test "cast-migrate.py: second run is idempotent (no dupes, no errors)" {
  python3 "$MIGRATE_SCRIPT" > /dev/null

  local count_before
  count_before=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")

  run python3 "$MIGRATE_SCRIPT"
  assert_success

  local count_after
  count_after=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")
  [ "$count_after" -eq "$count_before" ]
}

@test "cast-migrate.py: second run output says 0 applied" {
  python3 "$MIGRATE_SCRIPT" > /dev/null

  run python3 "$MIGRATE_SCRIPT"
  assert_success
  [[ "$output" == *"0 applied"* ]]
}

# ---------------------------------------------------------------------------
# Dry-run flag
# ---------------------------------------------------------------------------

@test "cast-migrate.py: --dry-run does not write any rows to schema_migrations" {
  run python3 "$MIGRATE_SCRIPT" --dry-run
  assert_success

  # Table may not even exist if no prior run
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null || echo 0)
  [ "$row_count" -eq 0 ]
}

@test "cast-migrate.py: --dry-run output contains PENDING for unapplied migrations" {
  run python3 "$MIGRATE_SCRIPT" --dry-run
  assert_success
  [[ "$output" == *"[PENDING]"* ]]
}
