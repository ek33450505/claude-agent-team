#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-cache-metrics.sh"

setup() {
  load 'helpers/setup'
  export ORIG_CAST_DB_PATH="${CAST_DB_PATH:-}"
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  teardown_temp_home
  if [ -n "$ORIG_CAST_DB_PATH" ]; then
    export CAST_DB_PATH="$ORIG_CAST_DB_PATH"
  else
    unset CAST_DB_PATH
  fi
}

# ---------------------------------------------------------------------------
# 1. schema missing: skip gracefully, write skipped-status report
# ---------------------------------------------------------------------------
@test "cache-metrics: skips gracefully when agent_runs cache columns are missing" {
  local test_db report_date report_file
  test_db="$(mktemp -d)/cast.db"
  sqlite3 "$test_db" "CREATE TABLE agent_runs (started_at TEXT);"

  run bash -c "CAST_DB_PATH='$test_db' bash '$HOOK_SH'"
  assert_success

  report_date="$(date +%Y-%m-%d)"
  report_file="$HOME/.claude/reports/cache-metrics-${report_date}.json"
  run cat "$report_file"
  assert_output --partial '"status": "skipped"'
}

# ---------------------------------------------------------------------------
# 2. ISO-T/Z vs space-form regression: agent_runs.started_at raw compare bug
#    (raw `started_at > datetime('now', '-30 days')` string-compared a stored
#    ISO-T/Z timestamp against sqlite's space-separated datetime('now',...)
#    form; 'T' (0x54) > ' ' (0x20) lexically, so a row at/before the 30-day
#    cutoff instant was falsely counted as "within the last 30 days". Fixed
#    by wrapping the column in datetime().)
# ---------------------------------------------------------------------------
@test "cache-metrics: agent_runs row at the ISO-T/space cutoff instant is NOT falsely counted" {
  local test_db threshold fixture_started_at report_date report_file
  test_db="$(mktemp -d)/cast.db"
  threshold="$(sqlite3 :memory: "SELECT datetime('now','-30 days');")"
  # Same instant as the cutoff, stored in the ISO-T/Z form the real column uses.
  fixture_started_at="${threshold%% *}T${threshold#* }Z"

  sqlite3 "$test_db" "CREATE TABLE agent_runs (started_at TEXT, cache_read_input_tokens INTEGER, cache_creation_input_tokens INTEGER, input_tokens INTEGER);"
  sqlite3 "$test_db" "INSERT INTO agent_runs (started_at, cache_read_input_tokens, cache_creation_input_tokens, input_tokens) VALUES ('$fixture_started_at', 999, 0, 0);"

  run bash -c "CAST_DB_PATH='$test_db' bash '$HOOK_SH'"
  assert_success

  report_date="$(date +%Y-%m-%d)"
  report_file="$HOME/.claude/reports/cache-metrics-${report_date}.json"
  # Correct: the cutoff instant is not strictly "within the last 30 days" ->
  # excluded -> cache_read_tokens stays 0, not the fixture's 999.
  run cat "$report_file"
  assert_output --partial '"cache_read_tokens": 0,'
  refute_output --partial '"cache_read_tokens": 999,'
}
