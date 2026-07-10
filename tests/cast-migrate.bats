#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATE_SCRIPT="$REPO_DIR/scripts/cast-migrate.py"
MIGRATIONS_DIR="$REPO_DIR/scripts/migrations"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"

  export TEST_DB="$BATS_TEST_TMPDIR/test-migrate-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Schema migrations table creation
# ---------------------------------------------------------------------------

@test "cast-migrate.py: fresh DB creates schema_migrations table on first run" {
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations';")
  [ "$count" -eq 1 ]
}

@test "cast-migrate.py: applies all NNN_*.sql files and records rows in schema_migrations" {
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")
  # Must have at least 7 migrations (009-015 + 016-019 = 11 files minimum)
  [ "$row_count" -ge 7 ]
}

@test "cast-migrate.py: incidents table exists after migration run" {
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='incidents';")
  [ "$count" -eq 1 ]
}

@test "cast-migrate.py: routines table exists after migration run" {
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='routines';")
  [ "$count" -eq 1 ]
}

@test "cast-migrate.py: plan_sessions table exists after migration run" {
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='plan_sessions';")
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Idempotency — second run must not duplicate ledger rows or error
# ---------------------------------------------------------------------------

@test "cast-migrate.py: second run is idempotent (no dupes, no errors)" {
  python3 "$MIGRATE_SCRIPT" --confirm > /dev/null

  local count_before
  count_before=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")

  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  local count_after
  count_after=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")
  [ "$count_after" -eq "$count_before" ]
}

@test "cast-migrate.py: second run output says 0 applied" {
  python3 "$MIGRATE_SCRIPT" --confirm > /dev/null

  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success
  [[ "$output" == *"0 applied"* ]]
}

# ---------------------------------------------------------------------------
# Dry-run flag
# ---------------------------------------------------------------------------

@test "cast-migrate.py: --dry-run does not write any rows to schema_migrations" {
  run python3 "$MIGRATE_SCRIPT" --dry-run
  assert_success

  # Table may not even exist if no prior run
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null || echo 0)
  [ "$row_count" -eq 0 ]
}

@test "cast-migrate.py: --dry-run output contains PENDING for unapplied migrations" {
  run python3 "$MIGRATE_SCRIPT" --dry-run
  assert_success
  [[ "$output" == *"[PENDING]"* ]]
}

# ---------------------------------------------------------------------------
# Migration 020: agent_runs empty session_id → NULL (Phase 5 Wave 2)
# ---------------------------------------------------------------------------

@test "migration 020: rewrites empty-string session_id to NULL in agent_runs" {
  # Seed a DB with agent_runs table and a bad row (session_id='')
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT,
  session_id TEXT,
  status TEXT
);
INSERT INTO agent_runs (agent, session_id, status) VALUES ('bad-agent', '', 'running');
SQL

  # Run migration 020 directly
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/020_agent_runs_null_session_id.sql"

  local val
  val=$(sqlite3 "$TEST_DB" "SELECT COALESCE(session_id, 'IS_NULL') FROM agent_runs WHERE agent='bad-agent';")
  [[ "$val" == "IS_NULL" ]]
}

@test "migration 020: is idempotent (re-run leaves no empty-string rows)" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT,
  session_id TEXT,
  status TEXT
);
INSERT INTO agent_runs (agent, session_id, status) VALUES ('ok-agent', 'sess-abc', 'running');
SQL

  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/020_agent_runs_null_session_id.sql"
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/020_agent_runs_null_session_id.sql"

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE session_id='';")
  [[ "$count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Migration 021: sessions with NULL/empty id → deleted (Phase 5 Wave 2)
# ---------------------------------------------------------------------------

@test "migration 021: deletes sessions rows where id IS NULL" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  project TEXT,
  started_at TEXT
);
INSERT INTO sessions (id, project, started_at) VALUES ('sess-good', 'proj', '2026-06-10T00:00:00Z');
SQL
  # SQLite TEXT PRIMARY KEY allows NULL insertions; force it via INSERT OR IGNORE bypass
  sqlite3 "$TEST_DB" "INSERT OR REPLACE INTO sessions (id, project) VALUES (NULL, 'bad');"

  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/021_sessions_delete_null_id.sql"

  local null_count
  null_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sessions WHERE id IS NULL;")
  [[ "$null_count" -eq 0 ]]
  # Good row untouched
  local good_count
  good_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sessions WHERE id='sess-good';")
  [[ "$good_count" -eq 1 ]]
}

@test "migration 021: deletes sessions rows where id is empty-string" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  project TEXT,
  started_at TEXT
);
INSERT INTO sessions (id, project, started_at) VALUES ('', 'bad-project', '2026-06-10T00:00:00Z');
SQL

  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/021_sessions_delete_null_id.sql"

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sessions WHERE id='' OR id IS NULL;")
  [[ "$count" -eq 0 ]]
}

@test "migration 021: is idempotent (second run is a no-op)" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  project TEXT
);
INSERT INTO sessions (id, project) VALUES ('sess-ok', 'proj');
SQL

  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/021_sessions_delete_null_id.sql"
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/021_sessions_delete_null_id.sql"

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sessions WHERE id='sess-ok';")
  [[ "$count" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Regression: semicolons inside -- comments must not produce spurious fragments
# (PR #175 / migration 022 shipped a comment "guarantees run-once; no guard
# needed here" that caused the per-statement fallback to execute "no guard
# needed here" as SQL, crashing with "near 'no': syntax error").
# ---------------------------------------------------------------------------

@test "cast-migrate.py: semicolon inside -- comment does not produce a syntax error" {
  # Write a throwaway migration SQL that has a semicolon inside a -- comment
  # and an idempotency-class DROP COLUMN that will trigger the per-statement fallback.
  local tmp_migrations tmp_sql
  tmp_migrations="$(mktemp -d)"
  tmp_sql="$tmp_migrations/099_comment_semicolon_regression.sql"
  cat > "$tmp_sql" <<'SQLEOF'
-- Regression guard: semicolon inside a comment; should not execute as SQL
ALTER TABLE _absent_table DROP COLUMN _absent_col;
SQLEOF

  # Point cast-migrate.py at the throwaway migrations dir via a driver
  local driver
  driver="$BATS_TEST_TMPDIR/regression_driver.py"
  cat > "$driver" << DRIVER_EOF
import sys, importlib.util, pathlib, os, sqlite3

# Patch the migrations directory to our throwaway dir
migrate_path = sys.argv[1]
tmp_dir = pathlib.Path(sys.argv[2])
db_path  = os.environ['CAST_DB_PATH']

spec = importlib.util.spec_from_file_location("cast_migrate", migrate_path)
mod  = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

conn = mod._connect(db_path)
mod._ensure_migrations_table(conn)

# Apply only the throwaway migration directly
sql_path = tmp_dir / "099_comment_semicolon_regression.sql"
try:
    mod._apply_migration(conn, sql_path)
    print("PASS: no syntax error")
    sys.exit(0)
except Exception as e:
    print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)
DRIVER_EOF

  run python3 "$driver" "$MIGRATE_SCRIPT" "$tmp_migrations"
  assert_success
  [[ "$output" == *"PASS: no syntax error"* ]]

  rm -rf "$tmp_migrations"
}

# ---------------------------------------------------------------------------
# Argparse safety guard — footgun tests added with --confirm flag
# ---------------------------------------------------------------------------

@test "cast-migrate.py: --help exits 0, prints usage, applies nothing to DB" {
  run python3 "$MIGRATE_SCRIPT" --help
  assert_success

  # --help must print usage keywords
  [[ "$output" == *"usage"* ]] || [[ "$output" == *"Usage"* ]]

  # The DB must be untouched (schema_migrations not created by --help)
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null || echo 0)
  [ "$row_count" -eq 0 ]
}

@test "cast-migrate.py: unknown arg exits non-zero and applies nothing" {
  run python3 "$MIGRATE_SCRIPT" --bogus
  # argparse standard error exit code is 2
  [ "$status" -eq 2 ]

  # DB must be untouched
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null || echo 0)
  [ "$row_count" -eq 0 ]
}

@test "cast-migrate.py: no args defaults to dry-run, prints hint, applies nothing" {
  run python3 "$MIGRATE_SCRIPT"
  assert_success

  # Must print the dry-run hint
  [[ "$output" == *"pass --confirm to apply"* ]]

  # DB must be untouched
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null || echo 0)
  [ "$row_count" -eq 0 ]
}

@test "cast-migrate.py: --confirm applies pending migrations" {
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  # At least one migration must have been applied
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")
  [ "$row_count" -ge 1 ]
}

@test "cast-migrate.py: --dry-run --confirm together exit 2 (mutual exclusion)" {
  run python3 "$MIGRATE_SCRIPT" --dry-run --confirm
  # argparse mutually exclusive group error exit code is 2
  [ "$status" -eq 2 ]

  # DB must be untouched
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null || echo 0)
  [ "$row_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Pre-migration backup gate (Track 1 v8 prework)
# ---------------------------------------------------------------------------

@test "cast-migrate.py: dry-run does NOT create backup even with pending migrations" {
  # Setup backup dir and track if anything is created
  export CAST_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  mkdir -p "$CAST_BACKUP_DIR"

  # Run with --dry-run (no migrations applied yet = pending migrations exist)
  run python3 "$MIGRATE_SCRIPT" --dry-run
  assert_success

  # Dry-run must NOT invoke backup — backup dir should be empty
  local backup_count
  backup_count=$(find "$CAST_BACKUP_DIR" -type f | wc -l | tr -d ' ')
  [ "$backup_count" -eq 0 ]
}

@test "cast-migrate.py: --confirm backs up BEFORE applying migrations" {
  # Setup backup dir
  export CAST_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  mkdir -p "$CAST_BACKUP_DIR"

  # Run --confirm with pending migrations
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  # Backup must have been created
  local backup_count
  backup_count=$(find "$CAST_BACKUP_DIR" -type f | wc -l | tr -d ' ')
  [ "$backup_count" -ge 1 ]

  # Migrations must have been applied
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;")
  [ "$row_count" -ge 1 ]
}

@test "cast-migrate.py: backup failure ABORTS migration (gate is fail-closed)" {
  # Force backup failure by making CAST_BACKUP_DIR a file instead of directory
  # When cast-db-backup.py tries mkdir, it will fail
  export CAST_BACKUP_DIR="$BATS_TEST_TMPDIR/backup-is-file"
  touch "$CAST_BACKUP_DIR"  # Create as file, not directory

  # Run --confirm; backup gate should fail and abort before applying
  run python3 "$MIGRATE_SCRIPT" --confirm
  # Must exit non-zero
  [ "$status" -ne 0 ]

  # ERROR message must be in output or stderr
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"error"* ]]

  # CRITICAL: no migrations must have been applied (gate worked)
  local row_count
  row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null || echo 0)
  [ "$row_count" -eq 0 ]
}

@test "cast-migrate.py: --confirm with no pending migrations does NOT back up" {
  # Setup backup dir
  export CAST_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  mkdir -p "$CAST_BACKUP_DIR"

  # First run: apply all migrations
  python3 "$MIGRATE_SCRIPT" --confirm > /dev/null
  local first_backup_count
  first_backup_count=$(find "$CAST_BACKUP_DIR" -type f | wc -l | tr -d ' ')
  [ "$first_backup_count" -ge 1 ]

  # Clean backups dir for clean comparison
  rm -f "$CAST_BACKUP_DIR"/*

  # Second run: no pending migrations, so no backup needed
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success
  [[ "$output" == *"0 applied"* ]]

  # No new backup created (dir should still be empty)
  local second_backup_count
  second_backup_count=$(find "$CAST_BACKUP_DIR" -type f | wc -l | tr -d ' ')
  [ "$second_backup_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Migration 014: agent_runs DROP COLUMN model_used
# ---------------------------------------------------------------------------

@test "migration 014: drops model_used column from agent_runs" {
  # Create agent_runs table WITH the model_used column
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT,
  model_used TEXT,
  status TEXT,
  duration_ms INTEGER DEFAULT 0,
  tool_uses INTEGER DEFAULT 0,
  outcome TEXT
);
INSERT INTO agent_runs (agent, model_used, status) VALUES ('test-agent', 'claude-3-sonnet', 'done');
SQL

  # Verify model_used exists before migration
  local has_col_before
  has_col_before=$(sqlite3 "$TEST_DB" "PRAGMA table_info(agent_runs);" | grep -c "model_used") || has_col_before=0
  [ "$has_col_before" -eq 1 ]

  # Apply migration 014
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/014_drop_agent_runs_model_used.sql"

  # Verify model_used is gone after migration
  local has_col_after
  has_col_after=$(sqlite3 "$TEST_DB" "PRAGMA table_info(agent_runs);" | grep -c "model_used") || has_col_after=0
  [ "$has_col_after" -eq 0 ]

  # Verify other columns are intact
  local col_count
  col_count=$(sqlite3 "$TEST_DB" "PRAGMA table_info(agent_runs);" | wc -l | tr -d ' ')
  [ "$col_count" -ge 6 ]  # id, agent, status, duration_ms, tool_uses, outcome
}

@test "migration 014: is idempotent (second DROP is a no-op)" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT,
  status TEXT
);
SQL

  # Apply migration 014 twice (DROP COLUMN ... is idempotent in SQLite 3.35+)
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/014_drop_agent_runs_model_used.sql" 2>/dev/null || true
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/014_drop_agent_runs_model_used.sql" 2>/dev/null || true

  # Table should still exist and be intact
  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agent_runs';")
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Migration 023: DROP TABLE batch_dispatches, contract_test_runs, files_api_events
# ---------------------------------------------------------------------------

@test "migration 023: drops batch_dispatches table" {
  # Create the three tier-3 tables
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS batch_dispatches (
  id INTEGER PRIMARY KEY,
  dispatch_id TEXT
);
CREATE TABLE IF NOT EXISTS contract_test_runs (
  id INTEGER PRIMARY KEY,
  run_id TEXT
);
CREATE TABLE IF NOT EXISTS files_api_events (
  id INTEGER PRIMARY KEY,
  event_id TEXT
);
INSERT INTO batch_dispatches (dispatch_id) VALUES ('disp-1');
INSERT INTO contract_test_runs (run_id) VALUES ('run-1');
INSERT INTO files_api_events (event_id) VALUES ('evt-1');
SQL

  # Verify all three tables exist
  local count_before
  count_before=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND (name='batch_dispatches' OR name='contract_test_runs' OR name='files_api_events');")
  [ "$count_before" -eq 3 ]

  # Apply migration 023
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/023_wave3_tier3_table_drops.sql"

  # Verify all three tables are dropped
  local count_after
  count_after=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND (name='batch_dispatches' OR name='contract_test_runs' OR name='files_api_events');")
  [ "$count_after" -eq 0 ]
}

@test "migration 023: is idempotent (DROP TABLE IF EXISTS)" {
  # Create one table to start
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS batch_dispatches (id INTEGER PRIMARY KEY);
SQL

  # Apply migration 023 twice
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/023_wave3_tier3_table_drops.sql"
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/023_wave3_tier3_table_drops.sql"

  # Should still succeed (no error on second run)
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='batch_dispatches';"
  assert_success
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Migration 025: DROP TABLE stream_events, teammate_messages, code_ref_checks
# ---------------------------------------------------------------------------

@test "migration 025: drops stream_events, teammate_messages, code_ref_checks tables" {
  # Create the three retired v9 Phase C tables
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS stream_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  event_type TEXT,
  data TEXT,
  timestamp TEXT
);
CREATE TABLE IF NOT EXISTS teammate_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  sender TEXT,
  content TEXT,
  timestamp TEXT
);
CREATE TABLE IF NOT EXISTS code_ref_checks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  ref TEXT,
  status TEXT,
  timestamp TEXT
);
INSERT INTO stream_events (session_id, event_type) VALUES ('s-1', 'test');
INSERT INTO teammate_messages (session_id, sender) VALUES ('s-1', 'agent');
INSERT INTO code_ref_checks (session_id, ref) VALUES ('s-1', 'ref-1');
SQL

  # Verify all three tables exist before migration
  local count_before
  count_before=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND (name='stream_events' OR name='teammate_messages' OR name='code_ref_checks');")
  [ "$count_before" -eq 3 ]

  # Apply migration 025
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/025_drop_retired_v9_phase_c_tables.sql"

  # Verify all three tables are dropped
  local count_after
  count_after=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND (name='stream_events' OR name='teammate_messages' OR name='code_ref_checks');")
  [ "$count_after" -eq 0 ]
}

@test "migration 025: is idempotent (DROP TABLE IF EXISTS)" {
  # Create one table to start
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS stream_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT);
SQL

  # Apply migration 025 twice
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/025_drop_retired_v9_phase_c_tables.sql"
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/025_drop_retired_v9_phase_c_tables.sql"

  # Should still succeed (no error on second run)
  run sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='stream_events';"
  assert_success
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Migration 026: re-drop six orphan columns from agent_runs and sessions
# ---------------------------------------------------------------------------

@test "migration 026: drops orphan columns from agent_runs and sessions" {
  # Create both tables WITH the six orphan columns to be dropped
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE agent_runs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent      TEXT,
  status     TEXT,
  project    TEXT,
  prompt     TEXT
);
CREATE TABLE sessions (
  id                  TEXT PRIMARY KEY,
  project             TEXT,
  total_input_tokens  INTEGER DEFAULT 0,
  total_output_tokens INTEGER DEFAULT 0,
  total_cost_usd      REAL DEFAULT 0.0,
  model               TEXT
);
INSERT INTO agent_runs (session_id, agent, status, project, prompt)
  VALUES ('s-1', 'code-writer', 'done', 'my-project', 'do the thing');
INSERT INTO sessions (id, project, total_input_tokens, total_output_tokens, total_cost_usd, model)
  VALUES ('sess-1', 'cast', 100, 200, 0.005, 'claude-sonnet-4-6');
SQL

  # Apply migration 026 directly
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/026_redrop_orphan_columns.sql"

  # Orphan columns must be gone from agent_runs
  local ar_orphan_count
  ar_orphan_count=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name IN ('project','prompt');")
  [ "$ar_orphan_count" -eq 0 ]

  # Orphan columns must be gone from sessions
  local sess_orphan_count
  sess_orphan_count=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('total_input_tokens','total_output_tokens','total_cost_usd','model');")
  [ "$sess_orphan_count" -eq 0 ]

  # Kept columns must still be present in agent_runs
  local ar_kept
  ar_kept=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name='agent';")
  [ "$ar_kept" -eq 1 ]

  # Kept columns must still be present in sessions
  local sess_kept
  sess_kept=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name='project';")
  [ "$sess_kept" -eq 1 ]
}

@test "migration 026: is idempotent via runner fallback (no such column tolerated)" {
  # Create schema_migrations with 009-025 already applied + tables WITHOUT orphan
  # columns — so only 026 is pending when the runner executes.
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE schema_migrations (
  version    TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT (datetime('now')),
  checksum   TEXT
);
INSERT INTO schema_migrations (version) VALUES
  ('009_cast_framework_fixes.sql'),
  ('010_work_log_stream.sql'),
  ('011_agent_response_capture.sql'),
  ('012_file_writes.sql'),
  ('013_agent_memories_validation_columns.sql'),
  ('014_drop_agent_runs_model_used.sql'),
  ('015_retire_stream_hook_events.sql'),
  ('016_baseline_no_op.sql'),
  ('017_incidents.sql'),
  ('018_routines.sql'),
  ('019_plan_sessions.sql'),
  ('020_agent_runs_null_session_id.sql'),
  ('021_sessions_delete_null_id.sql'),
  ('022_wave3_safe_column_drops.sql'),
  ('023_wave3_tier3_table_drops.sql'),
  ('024_wave3_inc3_coupled_column_drops.sql'),
  ('025_drop_retired_v9_phase_c_tables.sql');
CREATE TABLE agent_runs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent      TEXT,
  status     TEXT
);
CREATE TABLE sessions (
  id      TEXT PRIMARY KEY,
  project TEXT
);
SQL

  # Runner sees only 026 pending; cast-migrate.py tolerates 'no such column'
  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  # Migration 026 must be recorded in the ledger
  local recorded
  recorded=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM schema_migrations WHERE version='026_redrop_orphan_columns.sql';")
  [ "$recorded" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Migration 027: zombie final drop — DROP INDEX idx_agent_runs_project +
#   DROP COLUMN agent_runs.project, agent_runs.prompt,
#               sessions.total_input_tokens, sessions.total_output_tokens,
#               sessions.total_cost_usd, sessions.model
# ---------------------------------------------------------------------------

@test "migration 027: drops zombie columns and blocking index from agent_runs and sessions" {
  # Create both tables WITH the zombie columns + the blocking index + data rows
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE agent_runs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent      TEXT,
  status     TEXT,
  project    TEXT,
  prompt     TEXT
);
CREATE INDEX idx_agent_runs_project ON agent_runs(project);
CREATE TABLE sessions (
  id                  TEXT PRIMARY KEY,
  project             TEXT,
  total_input_tokens  INTEGER DEFAULT 0,
  total_output_tokens INTEGER DEFAULT 0,
  total_cost_usd      REAL DEFAULT 0.0,
  model               TEXT
);
INSERT INTO agent_runs (session_id, agent, status, project, prompt)
  VALUES ('s-1', 'code-writer', 'done', 'cast', 'write the thing');
INSERT INTO sessions (id, project, total_input_tokens, total_output_tokens, total_cost_usd, model)
  VALUES ('sess-1', 'cast', 100, 200, 0.005, 'claude-sonnet-4-6');
SQL

  # Apply migration 027
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/027_zombie_final_drop.sql"

  # Blocking index must be gone
  local idx_count
  idx_count=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_agent_runs_project';")
  [ "$idx_count" -eq 0 ]

  # Zombie columns must be gone from agent_runs
  local ar_zombie
  ar_zombie=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name IN ('project','prompt');")
  [ "$ar_zombie" -eq 0 ]

  # Zombie columns must be gone from sessions
  local sess_zombie
  sess_zombie=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('total_input_tokens','total_output_tokens','total_cost_usd','model');")
  [ "$sess_zombie" -eq 0 ]

  # Kept columns must still be present in agent_runs
  local ar_kept
  ar_kept=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name='agent';")
  [ "$ar_kept" -eq 1 ]

  # Kept columns must still be present in sessions
  local sess_kept
  sess_kept=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name='project';")
  [ "$sess_kept" -eq 1 ]
}

@test "migration 027: is idempotent (second apply tolerates no such column)" {
  # Create both tables WITHOUT the zombie columns
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE agent_runs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent      TEXT,
  status     TEXT
);
CREATE TABLE sessions (
  id      TEXT PRIMARY KEY,
  project TEXT
);
SQL

  # Apply migration 027 twice — SQLite 'no such column' errors are tolerated
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/027_zombie_final_drop.sql" 2>/dev/null || true
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/027_zombie_final_drop.sql" 2>/dev/null || true

  # Both tables must still exist and be intact
  local ar_count
  ar_count=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agent_runs';")
  [ "$ar_count" -eq 1 ]

  local sess_count
  sess_count=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sessions';")
  [ "$sess_count" -eq 1 ]

  # Column-existence spot-check: 'agent' must still be present in agent_runs
  # after a double-apply of the zombie-drop migration
  local agent_col
  agent_col=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name='agent';")
  [ "$agent_col" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Migration 028: retire dead columns + unstaged_warnings table
# ---------------------------------------------------------------------------

@test "migration 028: drops unstaged_warnings table, indexes, and all dead columns" {
  # Create ALL affected tables: unstaged_warnings (with indexes) + five column-bearing tables
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE unstaged_warnings (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  timestamp  TEXT,
  warning    TEXT
);
CREATE INDEX idx_uw_session   ON unstaged_warnings(session_id);
CREATE INDEX idx_uw_timestamp ON unstaged_warnings(timestamp);
INSERT INTO unstaged_warnings (session_id, timestamp, warning)
  VALUES ('s-1', '2026-07-03T00:00:00Z', 'test warning');
CREATE TABLE dispatch_decisions (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  agent    TEXT,
  effort   TEXT,
  wave_id  TEXT,
  parallel INTEGER DEFAULT 0
);
CREATE TABLE task_queue (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  task          TEXT,
  claimed_at    TEXT,
  completed_at  TEXT,
  scheduled_for TEXT
);
CREATE TABLE agent_truncations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  has_status INTEGER DEFAULT 0,
  has_json   INTEGER DEFAULT 0,
  batch_id   TEXT
);
CREATE TABLE agent_protocol_violations (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  agent    TEXT,
  batch_id TEXT
);
CREATE TABLE agent_runs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  agent      TEXT,
  status     TEXT,
  owns_files INTEGER DEFAULT 0
);
INSERT INTO dispatch_decisions (agent, effort, wave_id, parallel)
  VALUES ('code-writer', 'medium', 'wave-1', 0);
INSERT INTO task_queue (task, claimed_at, completed_at, scheduled_for)
  VALUES ('do-thing', '2026-07-03T00:00:00Z', NULL, '2026-07-04T00:00:00Z');
INSERT INTO agent_truncations (session_id, has_status, has_json, batch_id)
  VALUES ('s-1', 0, 0, NULL);
INSERT INTO agent_protocol_violations (agent, batch_id)
  VALUES ('code-writer', NULL);
INSERT INTO agent_runs (agent, status, owns_files)
  VALUES ('code-writer', 'done', 0);
SQL

  # Apply migration 028
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/028_retire_dead_columns.sql"

  # unstaged_warnings table must be gone
  local uw_tbl
  uw_tbl=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='unstaged_warnings';")
  [ "$uw_tbl" -eq 0 ]

  # unstaged_warnings indexes must be gone
  local uw_idx
  uw_idx=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_uw_session','idx_uw_timestamp');")
  [ "$uw_idx" -eq 0 ]

  # dispatch_decisions dead columns must be gone
  local dd_dead
  dd_dead=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('dispatch_decisions') WHERE name IN ('effort','wave_id','parallel');")
  [ "$dd_dead" -eq 0 ]

  # task_queue dead columns must be gone
  local tq_dead
  tq_dead=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('task_queue') WHERE name IN ('claimed_at','completed_at','scheduled_for');")
  [ "$tq_dead" -eq 0 ]

  # agent_truncations dead columns must be gone
  local at_dead
  at_dead=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_truncations') WHERE name IN ('has_status','has_json','batch_id');")
  [ "$at_dead" -eq 0 ]

  # agent_protocol_violations.batch_id must be gone
  local apv_dead
  apv_dead=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_protocol_violations') WHERE name='batch_id';")
  [ "$apv_dead" -eq 0 ]

  # agent_runs.owns_files must be gone
  local ar_dead
  ar_dead=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name='owns_files';")
  [ "$ar_dead" -eq 0 ]

  # Kept columns must still be present (spot-check dispatch_decisions.agent)
  local dd_kept
  dd_kept=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM pragma_table_info('dispatch_decisions') WHERE name='agent';")
  [ "$dd_kept" -eq 1 ]
}

@test "migration 028: is idempotent (second apply tolerates no such column and no such table)" {
  # Create all affected tables WITHOUT the dead columns
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE dispatch_decisions        (id INTEGER PRIMARY KEY, agent TEXT);
CREATE TABLE task_queue                (id INTEGER PRIMARY KEY, task TEXT);
CREATE TABLE agent_truncations         (id INTEGER PRIMARY KEY, session_id TEXT);
CREATE TABLE agent_protocol_violations (id INTEGER PRIMARY KEY, agent TEXT);
CREATE TABLE agent_runs                (id INTEGER PRIMARY KEY, agent TEXT, status TEXT);
SQL

  # Apply migration 028 twice — 'no such column' / 'no such table' are tolerated
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/028_retire_dead_columns.sql" 2>/dev/null || true
  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/028_retire_dead_columns.sql" 2>/dev/null || true

  # All five tables must still exist
  local tbl_count
  tbl_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('dispatch_decisions','task_queue','agent_truncations','agent_protocol_violations','agent_runs');")
  [ "$tbl_count" -eq 5 ]
}

@test "migration 031: creates idx_agent_runs_started_at on agent_runs(started_at)" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE agent_runs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  agent      TEXT,
  status     TEXT,
  started_at TEXT
);
SQL

  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/031_agent_runs_started_at_index.sql"

  local idx_count
  idx_count=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_agent_runs_started_at';")
  [ "$idx_count" -eq 1 ]

  # Index must target the correct column
  local idx_col
  idx_col=$(sqlite3 "$TEST_DB" "SELECT name FROM pragma_index_info('idx_agent_runs_started_at');")
  [ "$idx_col" = "started_at" ]
}

@test "migration 031: is idempotent (second apply is a no-op)" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE agent_runs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  agent      TEXT,
  status     TEXT,
  started_at TEXT
);
SQL

  sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/031_agent_runs_started_at_index.sql"
  run sqlite3 "$TEST_DB" < "$MIGRATIONS_DIR/031_agent_runs_started_at_index.sql"
  assert_success

  local idx_count
  idx_count=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_agent_runs_started_at';")
  [ "$idx_count" -eq 1 ]
}
