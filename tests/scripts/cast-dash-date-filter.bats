#!/usr/bin/env bats
# Tests for the started_at date normalization in cast-dash.py and bin/cast budget,
# and for the crashed-sessions doctor check 7-day started_at window.
# Verifies that both ISO-8601 T/Z rows and space-form rows are counted correctly
# by the replace()-based date normalization and that LIKE and DATE forms agree.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  load '../helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export TEST_DB="$(mktemp -p /tmp cast-dash-date-filter-XXXXXX.db)"
  export CAST_DB_PATH="$TEST_DB"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true

  # Insert one T/Z-form row and one space-form row, both for today (2026-06-11).
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, status, started_at, cost_usd)
     VALUES ('test-agent','DONE','2026-06-11T10:00:00Z', 0.50);"
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, status, started_at, cost_usd)
     VALUES ('test-agent','DONE','2026-06-11 11:00:00', 0.25);"
}

# Helper: insert a sessions row with status='crashed' and a started_at N days ago
_insert_crashed() {  # $1=days_ago
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, status, started_at)
     VALUES (lower(hex(randomblob(8))), 'crashed', datetime('now','-$1 days'));"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

@test "normalized date(replace()) query returns 2 rows for the test date" {
  run sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM agent_runs
     WHERE date(replace(replace(started_at,'T',' '),'Z',''))='2026-06-11';"
  assert_success
  assert_output "2"
}

@test "LIKE-based query and normalized DATE-based query return same SUM(cost_usd)" {
  _like_sum="$(sqlite3 "$TEST_DB" \
    "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs
     WHERE started_at LIKE '2026-06-11' || '%';")"
  _date_sum="$(sqlite3 "$TEST_DB" \
    "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs
     WHERE date(replace(replace(started_at,'T',' '),'Z',''))='2026-06-11';")"
  [ "$_like_sum" = "$_date_sum" ]
}

@test "normalized DATE query agrees with raw date(started_at) for both row formats" {
  _raw_sum="$(sqlite3 "$TEST_DB" \
    "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs
     WHERE date(started_at)='2026-06-11';")"
  _norm_sum="$(sqlite3 "$TEST_DB" \
    "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs
     WHERE date(replace(replace(started_at,'T',' '),'Z',''))='2026-06-11';")"
  [ "$_raw_sum" = "$_norm_sum" ]
}

# ── crashed-sessions 7-day window assertions ─────────────────────────────────

@test "crashed-sessions: row 2 days old IS counted in the 7d window" {
  _insert_crashed 2
  run sqlite3 "$TEST_DB" \
    "SELECT COALESCE(COUNT(*),0) FROM sessions
     WHERE status='crashed'
       AND replace(replace(started_at,'T',' '),'Z','') >= datetime('now','-7 days');"
  assert_success
  assert_output "1"
}

@test "crashed-sessions: row 8 days old is NOT counted in the 7d window" {
  _insert_crashed 8
  run sqlite3 "$TEST_DB" \
    "SELECT COALESCE(COUNT(*),0) FROM sessions
     WHERE status='crashed'
       AND replace(replace(started_at,'T',' '),'Z','') >= datetime('now','-7 days');"
  assert_success
  assert_output "0"
}

@test "crashed-sessions: only rows within 7d count when both inside and outside rows exist" {
  _insert_crashed 2   # inside window
  _insert_crashed 8   # outside window
  run sqlite3 "$TEST_DB" \
    "SELECT COALESCE(COUNT(*),0) FROM sessions
     WHERE status='crashed'
       AND replace(replace(started_at,'T',' '),'Z','') >= datetime('now','-7 days');"
  assert_success
  assert_output "1"
}
