#!/usr/bin/env bats
# cast-budget-alert-nodc.bats — Tests for cast-budget-alert.sh when cast.db is
# absent or empty. "nodc" = "no database connection" scenarios.
#
# These tests complement cast-budget-alert.bats (which tests the happy-path with
# a fully populated DB). Here we verify the script's silent-exit contract when the
# database is missing or has no budget data.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ALERT_SH="$REPO_DIR/scripts/cast-budget-alert.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1: CAST_DB_PATH points to a nonexistent file → exit 0, silent
# ---------------------------------------------------------------------------

@test "exits 0 when CAST_DB_PATH points to a nonexistent file" {
  export CAST_DB_PATH="/tmp/cast-no-such-db-$$.db"

  run bash "$ALERT_SH"

  assert_success
}

# ---------------------------------------------------------------------------
# Test 2: Nonexistent DB produces no error output on stderr
# ---------------------------------------------------------------------------

@test "produces no error output when cast.db is missing" {
  export CAST_DB_PATH="/tmp/cast-no-such-db-$$.db"

  # Capture stderr separately by redirecting
  local stderr_out
  stderr_out="$(bash "$ALERT_SH" 2>&1 >/dev/null)"

  # Stderr should be empty — no error messages
  [ -z "$stderr_out" ]
}

# ---------------------------------------------------------------------------
# Test 3: Empty SQLite DB (no tables) produces no alert output
# ---------------------------------------------------------------------------

@test "empty cast.db produces no alert" {
  local temp_db="/tmp/cast-empty-db-$$.db"
  # Create an empty (but valid) SQLite database
  sqlite3 "$temp_db" "PRAGMA journal_mode=WAL;"
  export CAST_DB_PATH="$temp_db"

  run bash "$ALERT_SH"

  assert_success
  refute_output --partial "[CAST-BUDGET"
  refute_output --partial "[CAST-BUDGET-HARD-LIMIT]"

  rm -f "$temp_db"
}

# ---------------------------------------------------------------------------
# Test 4: DB with sessions table but no budgets table → exit 0, no alert
# ---------------------------------------------------------------------------

@test "DB with sessions but no budgets table produces no alert" {
  local temp_db="/tmp/cast-sessions-only-$$.db"
  sqlite3 "$temp_db" \
    "CREATE TABLE sessions (
       id TEXT PRIMARY KEY,
       project TEXT,
       started_at TEXT,
       total_cost_usd REAL DEFAULT 0.0
     );
     INSERT INTO sessions VALUES ('s1', 'proj', '$(date +%Y-%m-%d)T10:00:00Z', 99.99);"
  export CAST_DB_PATH="$temp_db"

  run bash "$ALERT_SH"

  assert_success
  refute_output --partial "[CAST-BUDGET"

  rm -f "$temp_db"
}
