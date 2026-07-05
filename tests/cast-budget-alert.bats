#!/usr/bin/env bats
# Tests for the budget-alert path — retargeted to cast-subagent-stop-hook.sh (the
# consolidated SubagentStop hook that absorbed cast-budget-alert.sh at W2-1; the
# standalone script is deleted). Budget-alert behavior now runs as stage 14 of
# cast_subagent_stop.py; the banner strings and silent-exit assertions are IDENTICAL.
# Provisions via the REAL cast-db-init.sh schema (budgets, sessions cost columns,
# and agent_runs are all provisioned there now) — no hand-rolled fixtures. The
# alert sums today's spend from agent_runs.cost_usd, the same authoritative source
# `cast budget` reports. The hook needs a SubagentStop payload on stdin (a
# non-exempt agent with Status: DONE keeps the other stages quiet), so each
# invocation feeds $PAYLOAD.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"
CAST_BIN="$REPO_DIR/bin/cast"

# Minimal SubagentStop payload: a non-exempt agent that reported a terminal
# Status, so stages 4/5/12 (truncation/completeness) stay silent and only the
# budget stage can emit a banner.
PAYLOAD='{"agent_type":"x","session_id":"s1","agent_id":"a1","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: did work\nStatus: DONE"}]}}'

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export TEST_DB="/tmp/test-cast-budget-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

_set_budget() {  # $1=limit_usd  $2=alert_at_pct
  sqlite3 "$TEST_DB" \
    "INSERT INTO budgets (scope, scope_key, period, limit_usd, alert_at_pct, created_at)
     VALUES ('global','*','daily', $1, $2, datetime('now'));"
}

_spend_today() {  # $1=usd
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, status, started_at, cost_usd)
     VALUES ('x','DONE', strftime('%Y-%m-%dT%H:%M:%SZ','now'), $1);"
}

@test "exits 0 and is silent when DB file does not exist" {
  export CAST_DB_PATH="/nonexistent/path/to/cast.db"
  run bash "$HOOK_SH" <<< "$PAYLOAD"
  assert_success
  refute_output --partial "[CAST-BUDGET"
}

@test "exits 0 and is silent when no global daily budget is configured" {
  run bash "$HOOK_SH" <<< "$PAYLOAD"
  assert_success
  refute_output --partial "[CAST-BUDGET"
}

@test "prints [CAST-BUDGET-WARN] when daily spend reaches the warning threshold" {
  _set_budget 10.0 0.80
  _spend_today 8.50
  run bash "$HOOK_SH" <<< "$PAYLOAD"
  assert_success
  assert_output --partial "[CAST-BUDGET-WARN]"
}

@test "prints [CAST-BUDGET-HARD-LIMIT] when daily spend reaches or exceeds the limit" {
  _set_budget 10.0 0.80
  _spend_today 10.50
  run bash "$HOOK_SH" <<< "$PAYLOAD"
  assert_success
  assert_output --partial "[CAST-BUDGET-HARD-LIMIT]"
}

@test "stays silent when spend is below the warning threshold" {
  _set_budget 10.0 0.80
  _spend_today 2.00
  run bash "$HOOK_SH" <<< "$PAYLOAD"
  assert_success
  refute_output --partial "[CAST-BUDGET"
}

@test "cast budget set writes a global/daily row the alert reads" {
  run bash "$CAST_BIN" budget set --limit 4 --alert-at 0.75
  assert_success
  run sqlite3 "$TEST_DB" "SELECT limit_usd FROM budgets WHERE scope='global' AND period='daily';"
  assert_output "4.0"

  # Re-setting upserts (single row, not a duplicate).
  bash "$CAST_BIN" budget set --limit 9 >/dev/null
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM budgets WHERE scope='global' AND period='daily';"
  assert_output "1"

  # And the alert fires against a `cast budget set` limit.
  _spend_today 8.50
  run bash "$HOOK_SH" <<< "$PAYLOAD"
  assert_output --partial "[CAST-BUDGET-WARN]"
}

@test "cast budget set requires --limit" {
  run bash "$CAST_BIN" budget set
  assert_failure
}
