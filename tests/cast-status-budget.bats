#!/usr/bin/env bats
# Tests for cast status Budget line — reads budgets table as primary source.
# Task 2 of ~/.claude/plans/2026-06-12-v8-a0-verify-fixes.md
#
# 4 required cases:
#   1. configured + under limit  → renders $x / $y daily (pct%)
#   2. configured + exceeded     → pct ≥ 100, EXCEEDED, no "not configured"
#   3. nothing configured        → keeps "not configured" message
#   4. cast.db absent            → honest degradation, exit 0

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Shared setup / teardown — isolated temp HOME (HARD RULE)
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  mkdir -p "$HOME/.claude/agents" \
           "$HOME/.claude/config" \
           "$HOME/.claude/logs" \
           "$HOME/.claude/scripts"

  export CAST_DB_PATH="$HOME/.claude/cast-budget-test.db"

  # Full schema initialisation (creates budgets + agent_runs tables)
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  # Minimal settings.json so hook-count query does not blow up
  printf '{"hooks":{}}\n' > "$HOME/.claude/settings.json"
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# Helper: insert a global daily budget row
# ---------------------------------------------------------------------------
_insert_budget() {
  local limit="${1:-100.0}"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO budgets (scope, scope_key, period, limit_usd, alert_at_pct, created_at)
     VALUES ('global', '*', 'daily', ${limit}, 0.8, datetime('now'));"
}

# Helper: insert an agent_run with today's date and given cost
_insert_spend() {
  local cost="${1:-0.0}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_runs (agent, started_at, cost_usd, status)
     VALUES ('test-agent', '${ts}', ${cost}, 'DONE');"
}

# ---------------------------------------------------------------------------
# Test 1: configured + under limit
# ---------------------------------------------------------------------------

@test "budget configured and under limit renders spend / limit daily (pct%)" {
  _insert_budget 100.0
  _insert_spend 30.0

  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Budget"
  # Spend / limit with period
  assert_output --partial "/ \$100.00 daily"
  assert_output --partial "(30%)"
  # Budget line must NOT say "not configured"
  refute_output --partial "Budget      not configured"
  # Must NOT say "EXCEEDED" (30 < 100)
  refute_output --partial "EXCEEDED"
}

# ---------------------------------------------------------------------------
# Test 2: configured + exceeded
# ---------------------------------------------------------------------------

@test "budget configured and exceeded shows EXCEEDED, pct >=100, no not-configured" {
  _insert_budget 100.0
  _insert_spend 202.19

  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "EXCEEDED"
  # Budget line must NOT say "not configured"
  refute_output --partial "Budget      not configured"

  # Extract pct from the primary Budget line and assert >= 100
  local budget_line pct
  budget_line="$(printf '%s\n' "$output" | grep "^Budget " | grep -v "repo" | head -1)"
  # Extract the number inside (N%)
  pct="$(printf '%s\n' "$budget_line" | grep -oE '\([0-9]+%\)' | tr -d '()%')"
  [ "$(printf '%s' "$pct" | tr -d ' ')" -ge 100 ]
}

# ---------------------------------------------------------------------------
# Test 3: nothing configured → "not configured"
# ---------------------------------------------------------------------------

@test "budget not configured shows not configured message" {
  # No budgets row, no repo cast.json limit present
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "not configured"
}

# ---------------------------------------------------------------------------
# Test 4: cast.db absent → honest degradation, exit 0
# ---------------------------------------------------------------------------

@test "cast.db absent produces honest degradation line and exits 0" {
  rm -f "$CAST_DB_PATH"

  run bash "$CAST_CLI" status
  assert_success  # exit code must be 0
  # Should show a Budget line that is NOT the "not configured (run cast init-repo)" message
  assert_output --partial "Budget"
  refute_output --partial "not configured (run cast init-repo)"
  # Should mention the db is unavailable
  assert_output --partial "unavailable"
}
