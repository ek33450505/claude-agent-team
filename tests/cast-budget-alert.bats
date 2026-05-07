#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ALERT_SH="$REPO_DIR/scripts/cast-budget-alert.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude"

  export TEST_DB="/tmp/test-cast-budget-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Bootstrap minimal schema: init script creates core tables, then we
  # add the two tables that cast-budget-alert.sh reads directly.
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true

  # Ensure total_cost_usd column exists (cast-db-init.sh creates sessions without it)
  sqlite3 "$TEST_DB" \
    "ALTER TABLE sessions ADD COLUMN total_cost_usd REAL DEFAULT 0.0;" 2>/dev/null || true

  # budgets table (not created by cast-db-init.sh v8)
  sqlite3 "$TEST_DB" \
    "CREATE TABLE IF NOT EXISTS budgets (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      scope       TEXT,
      period      TEXT,
      limit_usd   REAL,
      alert_at_pct REAL DEFAULT 0.80
    );"

  # sessions table with total_cost_usd (cast-budget-alert reads this column
  # which is not part of the sessions table created by cast-db-init.sh)
  sqlite3 "$TEST_DB" \
    "CREATE TABLE IF NOT EXISTS sessions (
      id              TEXT PRIMARY KEY,
      project         TEXT,
      project_root    TEXT,
      started_at      TEXT,
      ended_at        TEXT,
      model           TEXT,
      total_cost_usd  REAL DEFAULT 0.0
    );"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Test 1: CAST_DB_PATH points to a file that does not exist
#          → script must exit 0 and produce no output
# ---------------------------------------------------------------------------

@test "exits 0 and is silent when DB file does not exist" {
  export CAST_DB_PATH="/nonexistent/path/to/cast.db"

  run bash "$ALERT_SH"

  assert_success
  refute_output --partial "[CAST-BUDGET"
  refute_output --partial "[CAST-BUDGET-HARD-LIMIT]"
}

# ---------------------------------------------------------------------------
# Test 2: DB exists and has core schema, but no budgets table row
#          → script must exit 0 and produce no output
# ---------------------------------------------------------------------------

@test "exits 0 and is silent when no global daily budget is configured" {
  # sessions table is empty; budgets table has no global/daily row
  run bash "$ALERT_SH"

  assert_success
  refute_output --partial "[CAST-BUDGET"
  refute_output --partial "[CAST-BUDGET-HARD-LIMIT]"
}

# ---------------------------------------------------------------------------
# Test 3: DB has a global daily budget row; today's spend >= 80% of limit
#          → script must print a string containing [CAST-BUDGET-WARN]
# ---------------------------------------------------------------------------

@test "prints [CAST-BUDGET-WARN] when daily spend reaches warning threshold" {
  # Insert a global/daily budget: $10.00 limit, 80% warning threshold (default)
  sqlite3 "$TEST_DB" \
    "INSERT INTO budgets (scope, period, limit_usd, alert_at_pct)
     VALUES ('global', 'daily', 10.0, 0.80);"

  # Insert a session for today with $8.50 spend (85% of $10 limit → triggers warn)
  local today
  today="$(date +%Y-%m-%d)"
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, project, started_at, total_cost_usd)
     VALUES ('test-session-1', 'test-project', '${today}T10:00:00Z', 8.50);"

  run bash "$ALERT_SH"

  assert_success
  assert_output --partial "[CAST-BUDGET-WARN]"
}

# ---------------------------------------------------------------------------
# Test 4: DB has a global daily budget row; today's spend >= 100% of limit
#          → script must print a string containing [CAST-BUDGET-HARD-LIMIT]
# ---------------------------------------------------------------------------

@test "prints [CAST-BUDGET-HARD-LIMIT] when daily spend reaches or exceeds the limit" {
  # Insert a global/daily budget: $10.00 limit, 80% warning threshold (default)
  sqlite3 "$TEST_DB" \
    "INSERT INTO budgets (scope, period, limit_usd, alert_at_pct)
     VALUES ('global', 'daily', 10.0, 0.80);"

  # Insert a session for today with $10.50 spend (105% of $10 limit → triggers hard limit)
  local today
  today="$(date +%Y-%m-%d)"
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, project, started_at, total_cost_usd)
     VALUES ('test-session-2', 'test-project', '${today}T10:00:00Z', 10.50);"

  run bash "$ALERT_SH"

  assert_success
  assert_output --partial "[CAST-BUDGET-HARD-LIMIT]"
}
