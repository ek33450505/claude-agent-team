#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude"

  export TEST_DB="/tmp/test-cast-init-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
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

  # Check all required columns exist (batch_id/has_status/has_json retired in migration 028)
  local schema
  schema=$(sqlite3 "$TEST_DB" ".schema agent_truncations")

  [[ "$schema" == *"id"* ]]
  [[ "$schema" == *"session_id"* ]]
  [[ "$schema" == *"agent_type"* ]]
  [[ "$schema" == *"agent_id"* ]]
  [[ "$schema" == *"last_line"* ]]
  [[ "$schema" == *"timestamp"* ]]
  [[ "$schema" == *"char_count"* ]]
  [[ "$schema" == *"partial_work_log"* ]]

  # Retired columns must be absent
  [[ "$schema" != *"batch_id"* ]]
  [[ "$schema" != *"has_status"* ]]
  [[ "$schema" != *"has_json"* ]]

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
  # Regression companion: the agent_runs column self-heal (response/agent_id)
  # also lived past the early exit and was unreachable for v8 DBs. Drop ONLY the
  # 'response' column (a later additive column) to reproduce a realistic old-v8 DB.
  # batch_id was dropped in migration 024 (wave-3 inc3) and is no longer self-healed.
  bash "$DB_INIT" --db "$TEST_DB"
  sqlite3 "$TEST_DB" "ALTER TABLE agent_runs DROP COLUMN response; PRAGMA user_version=8;"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name='response';"
  assert_output "0"

  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name='response';"
  assert_output "1"
}

# ---------------------------------------------------------------------------
# Phase 3 UNIT B: provision the tables/columns that had live writers but were
# only created by the now-defunct migration runners (init = source of truth).
# ---------------------------------------------------------------------------

@test "cast-db-init provisions all formerly-migration-only tables on a fresh DB" {
  bash "$DB_INIT" --db "$TEST_DB"
  for tbl in routines incidents plan_sessions memory_consolidation_runs archived_memories budgets; do
    run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$tbl';"
    assert_output "$tbl"
  done
}

@test "cast-db-init sessions: status+deleted_at present, wave-3 cost-rollup columns absent" {
  bash "$DB_INIT" --db "$TEST_DB"
  # status and deleted_at survive wave-3 — assert present
  for col in status deleted_at; do
    run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('sessions') WHERE name='$col';"
    assert_output "1"
  done
  # total_input_tokens / total_output_tokens / total_cost_usd dropped in migration 022 (wave-3)
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('sessions') WHERE name IN ('total_input_tokens','total_output_tokens','total_cost_usd');"
  assert_output "0"
}

@test "cast-db-init routing_events: wave-3 attribution columns absent from fresh init" {
  bash "$DB_INIT" --db "$TEST_DB"
  # agent_id / agent_type / match_type dropped in migration 022 (wave-3)
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('routing_events') WHERE name IN ('agent_id','agent_type','match_type');"
  assert_output "0"
  # INSERT using only the surviving columns must succeed
  run sqlite3 "$TEST_DB" "INSERT INTO routing_events (session_id, timestamp, prompt_preview, action, matched_route, pattern, confidence, project) VALUES ('s','t','p','a','m','pat','c','proj');"
  assert_success
}

@test "cast-db-init: agent_runs.owns_files retired (migration 028 — col absent)" {
  # owns_files was retired in migration 028 per wave-2 schema cleanup; must not exist
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name='owns_files';"
  assert_output "0"
}

@test "cast-db-init re-provisions formerly-migration-only tables on an existing v8 DB missing them" {
  bash "$DB_INIT" --db "$TEST_DB"
  sqlite3 "$TEST_DB" "DROP TABLE routines; DROP TABLE incidents; DROP TABLE memory_consolidation_runs; DROP TABLE budgets; PRAGMA user_version=8;"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('routines','incidents','memory_consolidation_runs','budgets');"
  assert_output "0"

  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
  for tbl in routines incidents memory_consolidation_runs budgets; do
    run sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$tbl';"
    assert_output "$tbl"
  done
}

@test "cast-db-init routines/budgets accept their live writer shapes" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "INSERT INTO routines (id,name,trigger_type,agent_to_dispatch,prompt_template,output_dir,created_at) VALUES ('r1','nightly','cron','docs','do x','/tmp/out','2026-06-03');"
  assert_success
  run sqlite3 "$TEST_DB" "INSERT INTO budgets (scope,scope_key,period,limit_usd,alert_at_pct,created_at) VALUES ('global','*','daily',10.0,0.8,'2026-06-03');"
  assert_success
}

# ---------------------------------------------------------------------------
# Phase 3 UNIT E: cast-db-init.sh owns schema_migrations with the canonical
# (version/applied_at/checksum) shape. cast-migrate.py used a divergent
# (migration_name) shape and errored against an init/sh-created table. Both
# runners now agree with init.
# ---------------------------------------------------------------------------

@test "cast-db-init provisions schema_migrations with the canonical version column" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('schema_migrations') WHERE name='version';"
  assert_output "1"
  # The legacy divergent column must NOT be what init creates.
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('schema_migrations') WHERE name='migration_name';"
  assert_output "0"
}

@test "cast-migrate.py runs clean against an init-provisioned schema_migrations (divergence fix)" {
  bash "$DB_INIT" --db "$TEST_DB"
  run env CAST_DB_PATH="$TEST_DB" python3 "$REPO_DIR/scripts/cast-migrate.py" --confirm
  assert_success
}

# ---------------------------------------------------------------------------
# v7.4.0: init-authoritative column hygiene
# agent_runs.(duration_ms, tool_uses) and dispatch_decisions.outcome must be
# declared in the fresh-install CREATE TABLE and self-healed on existing DBs.
# ---------------------------------------------------------------------------

@test "cast-db-init provisions agent_runs.duration_ms and tool_uses on fresh DB" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name IN ('duration_ms','tool_uses');"
  assert_output "2"
}

@test "cast-db-init provisions dispatch_decisions.outcome on fresh DB" {
  bash "$DB_INIT" --db "$TEST_DB"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('dispatch_decisions') WHERE name='outcome';"
  assert_output "1"
}

@test "cast-db-init dispatch_decisions.outcome has default 'pending'" {
  bash "$DB_INIT" --db "$TEST_DB"
  sqlite3 "$TEST_DB" "INSERT INTO dispatch_decisions (session_id, chosen_agent) VALUES ('s1','code-writer');"
  run sqlite3 "$TEST_DB" "SELECT outcome FROM dispatch_decisions WHERE chosen_agent='code-writer';"
  assert_output "pending"
}

@test "cast-db-init self-heals agent_runs.duration_ms + tool_uses on existing DB missing them" {
  bash "$DB_INIT" --db "$TEST_DB"
  sqlite3 "$TEST_DB" "ALTER TABLE agent_runs DROP COLUMN duration_ms; ALTER TABLE agent_runs DROP COLUMN tool_uses;"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name IN ('duration_ms','tool_uses');"
  assert_output "0"

  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('agent_runs') WHERE name IN ('duration_ms','tool_uses');"
  assert_output "2"
}

@test "cast-db-init self-heals dispatch_decisions.outcome on existing DB missing it" {
  bash "$DB_INIT" --db "$TEST_DB"
  sqlite3 "$TEST_DB" "ALTER TABLE dispatch_decisions DROP COLUMN outcome;"
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('dispatch_decisions') WHERE name='outcome';"
  assert_output "0"

  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM pragma_table_info('dispatch_decisions') WHERE name='outcome';"
  assert_output "1"
}

@test "cast-db-init table count is exactly 40 on fresh DB" {
  bash "$DB_INIT" --db "$TEST_DB"
  # Exclude sqlite_* internals AND the record_fts% FTS5 apparatus (virtual table + shadow tables = a full-text index, not data tables; record_embed IS counted). Source of truth: scripts/cast-db-init.sh.
  # Count: 41 → 39 after retiring stream_events + teammate_messages (v9 Phase C U7a) → 38 after retiring code_ref_checks (v9 Phase C U7b) → 39 after adding commit_provenance (D5) → 38 after retiring unstaged_warnings (migration 028 wave-2) → 40 after adding agent_runs_daily + mcp_calls_daily (v10 C5 pre-prune rollup).
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'record_fts%';"
  assert_output "40"
}

@test "cast-db-init table count stays 40 on second invocation (idempotent)" {
  bash "$DB_INIT" --db "$TEST_DB"
  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
  # Exclude sqlite_* internals AND the record_fts% FTS5 apparatus (virtual table + shadow tables = a full-text index, not data tables; record_embed IS counted). Source of truth: scripts/cast-db-init.sh.
  # Count: 41 → 39 after retiring stream_events + teammate_messages (v9 Phase C U7a) → 38 after retiring code_ref_checks (v9 Phase C U7b) → 39 after adding commit_provenance (D5) → 38 after retiring unstaged_warnings (migration 028 wave-2) → 40 after adding agent_runs_daily + mcp_calls_daily (v10 C5 pre-prune rollup).
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'record_fts%';"
  assert_output "40"
}
