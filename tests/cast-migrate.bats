#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATE_SCRIPT="$REPO_DIR/scripts/cast-migrate.py"
MIGRATIONS_DIR="$REPO_DIR/scripts/migrations"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude"

  export TEST_DB="$BATS_TEST_TMPDIR/test-migrate-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
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
