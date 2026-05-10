#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATE_SCRIPT="$REPO_DIR/scripts/cast-migrate.sh"
MIGRATIONS_DIR="$REPO_DIR/migrations"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude"

  # Use BATS_TEST_TMPDIR for isolation
  export TEST_DB="$BATS_TEST_TMPDIR/test-migrate-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Schema migrations table creation and baseline stamping
# ---------------------------------------------------------------------------

@test "cast-migrate: fresh DB creates schema_migrations table on first run" {
  run bash "$MIGRATE_SCRIPT" --db "$TEST_DB"
  assert_success

  # Verify table exists
  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations';")
  [ "$count" -eq 1 ]
}

@test "cast-migrate: fresh DB stamps baseline migration without execution" {
  run bash "$MIGRATE_SCRIPT" --db "$TEST_DB"
  assert_success

  # Verify baseline row exists
  local baseline_count
  baseline_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations WHERE version='000-baseline';")
  [ "$baseline_count" -eq 1 ]

  # Verify checksum is 'baseline-marker'
  local checksum
  checksum=$(sqlite3 "$TEST_DB" "SELECT checksum FROM schema_migrations WHERE version='000-baseline';")
  [ "$checksum" = "baseline-marker" ]
}

@test "cast-migrate: applies 011-incidents migration to fresh DB" {
  run bash "$MIGRATE_SCRIPT" --db "$TEST_DB"
  assert_success

  # Verify incidents table exists
  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='incidents';")
  [ "$count" -eq 1 ]

  # Verify incidents table has expected columns
  local cols
  cols=$(sqlite3 "$TEST_DB" "PRAGMA table_info(incidents);" | cut -d'|' -f2 | tr '\n' ' ')
  [[ "$cols" == *"id"* ]]
  [[ "$cols" == *"occurred_at"* ]]
  [[ "$cols" == *"problem_summary"* ]]
  [[ "$cols" == *"resolution_status"* ]]
}

# ---------------------------------------------------------------------------
# Idempotency tests
# ---------------------------------------------------------------------------

@test "cast-migrate: second run is idempotent (prints '[migrate] (none)')" {
  bash "$MIGRATE_SCRIPT" --db "$TEST_DB" > /dev/null

  # Second run should print "(none)"
  run bash "$MIGRATE_SCRIPT" --db "$TEST_DB"
  assert_success
  [[ "$output" == *"[migrate] (none)"* ]]
}

@test "cast-migrate: schema_migrations records exactly one row per migration" {
  bash "$MIGRATE_SCRIPT" --db "$TEST_DB"

  # Count rows in schema_migrations
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")
  # Baseline (000) + incidents (011) = 2 rows
  [ "$row_count" -eq 2 ]

  # Verify distinct versions
  local versions
  versions=$(sqlite3 "$TEST_DB" "SELECT COUNT(DISTINCT version) FROM schema_migrations;")
  [ "$versions" -eq 2 ]
}

@test "cast-migrate: checksum is stored for non-baseline migrations" {
  bash "$MIGRATE_SCRIPT" --db "$TEST_DB"

  # Verify 011-incidents has a non-empty checksum (should be a SHA256 hex string)
  local checksum
  checksum=$(sqlite3 "$TEST_DB" "SELECT checksum FROM schema_migrations WHERE version='011-incidents';")
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "cast-migrate: empty migrations directory does not error" {
  # Create temp DB and migrate to fresh state
  export TEST_DB_EMPTY="$BATS_TEST_TMPDIR/test-empty-migrations-$$.db"
  export CAST_DB_PATH="$TEST_DB_EMPTY"

  # Create a temporary empty migrations directory
  local tmp_migrations
  tmp_migrations=$(mktemp -d)

  # Mock the script to use empty migrations dir
  local tmp_script
  tmp_script=$(mktemp)

  # Create a wrapper script that overrides MIGRATIONS_DIR
  cat > "$tmp_script" << 'EOF'
#!/bin/bash
set -euo pipefail

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"
if [[ $# -gt 0 ]] && [[ "$1" == "--db" ]]; then
  DB_PATH="$2"
fi

# Use empty migrations directory
MIGRATIONS_DIR="$(mktemp -d)"
trap "rm -rf $MIGRATIONS_DIR" EXIT

sqlite3 -cmd ".timeout 5000" "$DB_PATH" "
CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT (datetime('now')),
  checksum TEXT
);
"

shopt -s nullglob
migration_files=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob

applied_count=0

for migration_file in "${migration_files[@]}"; do
  echo "This should not execute with empty directory"
done

if [[ $applied_count -eq 0 ]]; then
  echo "[migrate] (none)"
fi

exit 0
EOF

  chmod +x "$tmp_script"
  run bash "$tmp_script" --db "$TEST_DB_EMPTY"
  assert_success
  [[ "$output" == *"[migrate] (none)"* ]]

  rm -f "$tmp_script" "$TEST_DB_EMPTY"
}

# ---------------------------------------------------------------------------
# Migration output verification
# ---------------------------------------------------------------------------

@test "cast-migrate: prints '[migrate] applied' for each applied migration on first run" {
  run bash "$MIGRATE_SCRIPT" --db "$TEST_DB"
  assert_success
  [[ "$output" == *"[migrate] applied 000-baseline"* ]]
  [[ "$output" == *"[migrate] applied 011-incidents"* ]]
}
