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

# ---------------------------------------------------------------------------
# Phase 2 Unit 2: 4 previously-missing tables now provisioned on fresh DB
# ---------------------------------------------------------------------------

@test "cast-db-init creates injection_log table" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='injection_log';"
  assert_output "injection_log"
}

@test "cast-db-init creates quality_gates table" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='quality_gates';"
  assert_output "quality_gates"
}

@test "cast-db-init creates dispatch_decisions table" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='dispatch_decisions';"
  assert_output "dispatch_decisions"
}

@test "cast-db-init creates task_queue table" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='task_queue';"
  assert_output "task_queue"
}

@test "cast-db-init all 4 new tables present in fresh DB" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" ".tables"
  assert_output --partial "injection_log"
  assert_output --partial "quality_gates"
  assert_output --partial "dispatch_decisions"
  assert_output --partial "task_queue"
}

@test "cast-db-init new tables are idempotent (v8+ re-init)" {
  bash "$DB_INIT" --db "$TEST_DB"
  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
  run sqlite3 "$TEST_DB" ".tables"
  assert_output --partial "injection_log"
  assert_output --partial "quality_gates"
  assert_output --partial "dispatch_decisions"
  assert_output --partial "task_queue"
}

@test "injection_log has correct columns matching live writer" {
  bash "$DB_INIT" --db "$TEST_DB"
  local schema
  schema=$(sqlite3 "$TEST_DB" ".schema injection_log")
  [[ "$schema" == *"session_id"* ]]
  [[ "$schema" == *"prompt_hash"* ]]
  [[ "$schema" == *"fact_id"* ]]
  [[ "$schema" == *"score"* ]]
  [[ "$schema" == *"score_breakdown"* ]]
  [[ "$schema" == *"injected_at"* ]]
}

@test "quality_gates accepts live writer INSERT (TEXT id, agent_name, no batch_id)" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" \
    "INSERT INTO quality_gates (id, session_id, agent_name, timestamp, status_line, contract_passed, retry_count) VALUES ('test-uuid-1', 'sess-1', 'code-reviewer', '2026-06-03T00:00:00Z', 'DONE', 1, 0);"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM quality_gates;"
  assert_output "1"
}

@test "task_queue accepts live writer INSERT (with project and project_root)" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" \
    "INSERT INTO task_queue (created_at, project, project_root, agent, task, status) VALUES ('2026-06-03T00:00:00Z', 'cast', '/home/user/cast', 'background', 'test-task', 'running');"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM task_queue;"
  assert_output "1"
}
