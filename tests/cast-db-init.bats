#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude"

  export TEST_DB="/tmp/test-cast-init-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Phase 4.10: agent_truncations table created in fresh DB
# ---------------------------------------------------------------------------

@test "cast-db-init creates agent_truncations table in fresh env" {
  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success

  run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_truncations';"
  assert_output "agent_truncations"
}

@test "cast-db-init agent_truncations creation is idempotent" {
  bash "$DB_INIT" --db "$TEST_DB"
  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success

  run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_truncations';"
  assert_output "agent_truncations"
}

@test "cast-db-init agent_truncations has required columns and indexes" {
  bash "$DB_INIT" --db "$TEST_DB"

  # Check all required columns exist
  local schema
  schema=$(sqlite3 "$TEST_DB" ".schema agent_truncations")

  [[ "$schema" == *"id"* ]]
  [[ "$schema" == *"session_id"* ]]
  [[ "$schema" == *"agent_type"* ]]
  [[ "$schema" == *"agent_id"* ]]
  [[ "$schema" == *"batch_id"* ]]
  [[ "$schema" == *"last_line"* ]]
  [[ "$schema" == *"timestamp"* ]]
  [[ "$schema" == *"char_count"* ]]
  [[ "$schema" == *"has_status"* ]]
  [[ "$schema" == *"has_json"* ]]
  [[ "$schema" == *"partial_work_log"* ]]

  # Check indexes exist
  [[ "$schema" == *"idx_at_session"* ]]
  [[ "$schema" == *"idx_at_agent_type"* ]]
}
