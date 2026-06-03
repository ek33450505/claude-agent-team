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

# ---------------------------------------------------------------------------
# Phase 3 #1 regression: the v8 EARLY-EXIT bug.
# An existing v8 DB that predates the consolidated tables (injection_log,
# quality_gates, dispatch_decisions, task_queue, agent_truncations) must get
# them re-provisioned on re-init. The old `exit 0` in the v8+ branch made the
# unconditional self-healing block unreachable, so these tables were NEVER
# created on any existing v8 DB — only on fresh installs (different code path).
# The pre-existing "v8+ re-init" idempotency test could not catch this because
# it re-inits a COMPLETE DB; this test drops the tables first to reproduce a
# real old-v8 instance.
# ---------------------------------------------------------------------------

@test "cast-db-init re-provisions self-healing tables on an existing v8 DB missing them" {
  # Build a complete DB, then simulate an OLD v8 instance that lacks the
  # consolidated tables while remaining at user_version=8.
  bash "$DB_INIT" --db "$TEST_DB"
  sqlite3 "$TEST_DB" "DROP TABLE injection_log; DROP TABLE quality_gates; DROP TABLE dispatch_decisions; DROP TABLE task_queue; DROP TABLE agent_truncations; PRAGMA user_version=8;"

  # Sanity: confirm the precondition (tables really gone, still v8).
  run sqlite3 "$TEST_DB" "PRAGMA user_version;"
  assert_output "8"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('injection_log','quality_gates','dispatch_decisions','task_queue','agent_truncations');"
  assert_output "0"

  # Re-run init: self-healing block MUST run despite the v8 short-circuit.
  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success

  # All five self-healing tables must be back.
  for tbl in injection_log quality_gates dispatch_decisions task_queue agent_truncations; do
    run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$tbl';"
    assert_output "$tbl"
  done
}

@test "cast-db-init self-heals a missing agent_runs column on an existing v8 DB" {
  # Regression companion: the agent_runs column self-heal (response/agent_id/batch_id)
  # also lived past the early exit and was unreachable for v8 DBs. Drop ONLY the
  # 'response' column (a later additive column) to reproduce a realistic old-v8 DB.
  bash "$DB_INIT" --db "$TEST_DB"
  sqlite3 "$TEST_DB" "ALTER TABLE agent_runs DROP COLUMN response; PRAGMA user_version=8;"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name='response';"
  assert_output "0"

  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name='response';"
  assert_output "1"
}
