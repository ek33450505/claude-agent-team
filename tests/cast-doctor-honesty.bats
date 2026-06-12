#!/usr/bin/env bats
# Tests for the cast doctor honesty surface (section 13)
# Encodes the honest-degradation contract: missing table = INFO, not green OK.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# DDL for the four honesty tables (sourced from scripts/cast-db-init.sh)
_create_honesty_tables() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_hallucinations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    agent_name TEXT NOT NULL,
    claim_type TEXT NOT NULL,
    claimed_value TEXT,
    actual_value TEXT,
    verified INTEGER DEFAULT 0,
    timestamp TEXT
);
CREATE TABLE IF NOT EXISTS completeness_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT NOT NULL,
    truncated_at TEXT NOT NULL,
    snippet TEXT,
    severity TEXT DEFAULT 'MEDIUM',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT,
    agent_type   TEXT NOT NULL,
    agent_id     TEXT,
    batch_id     INTEGER,
    violation    TEXT NOT NULL,
    pattern      TEXT,
    timestamp    TEXT NOT NULL,
    raw_excerpt  TEXT
);
CREATE TABLE IF NOT EXISTS code_ref_checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    agent_name TEXT,
    ref_type TEXT,
    ref_name TEXT,
    verified INTEGER,
    location TEXT,
    timestamp TEXT
);
SQL
}

# Minimal cast.db with the required tables that cast doctor checks before the
# honesty block (sessions, agent_runs, routing_events, etc.)
_create_minimal_core_tables() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT, model TEXT, project_dir TEXT, session_type TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0.0, duration_ms INTEGER, tool_uses INTEGER DEFAULT 0, outcome TEXT);
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, started_at TEXT, ended_at TEXT, status TEXT, duration_ms INTEGER, tool_uses INTEGER, outcome TEXT);
CREATE TABLE IF NOT EXISTS routing_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, matched_route TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, confidence REAL DEFAULT 1.0, last_validated_at TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS stream_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS swarm_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, status TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS teammate_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, teammate_name TEXT, started_at TEXT, status TEXT);
CREATE TABLE IF NOT EXISTS teammate_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, role TEXT, content TEXT, ts TEXT);
CREATE TABLE IF NOT EXISTS tool_call_failures (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, tool_name TEXT, error TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_truncations (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, truncated_at TEXT, severity TEXT, snippet TEXT);
CREATE TABLE IF NOT EXISTS injection_log (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, injected_at TEXT, source TEXT, content_preview TEXT);
CREATE TABLE IF NOT EXISTS quality_gates (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, gate_name TEXT, result TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS dispatch_decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, reason TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS task_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, task_name TEXT, agent TEXT, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS routines (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, agent TEXT, schedule TEXT, status TEXT, last_run TEXT);
CREATE TABLE IF NOT EXISTS incidents (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, severity TEXT, description TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS plan_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, plan_file TEXT, status TEXT, started_at TEXT, ended_at TEXT);
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ran_at TEXT, merged_count INTEGER, pruned_count INTEGER);
CREATE TABLE IF NOT EXISTS archived_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, archived_at TEXT);
CREATE TABLE IF NOT EXISTS budgets (id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT, budget_usd REAL, spent_usd REAL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);
SQL
}

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CLAUDE_SUBPROCESS=0
  # Point to the repo's agents dir so doctor doesn't error on missing agents
  export CAST_AGENTS_DIR="$REPO_DIR/agents/core"
}

teardown() {
  teardown_temp_home
}

# ── Helper: run cast doctor and capture combined stdout+stderr ───────────────
_run_doctor() {
  run bash "$CAST_BIN" doctor 2>&1
}

# ── Test 1: Tables absent — no honesty tables provisioned ───────────────────
@test "tables absent: reports INFO 'no data yet' for each honesty table" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  # Do NOT create any of the four honesty tables

  _run_doctor

  # Should contain the INFO 'no data yet' pattern for all four tables
  assert_output --partial "agent_hallucinations — no data yet"
  assert_output --partial "completeness_events — no data yet"
  assert_output --partial "agent_protocol_violations — no data yet"
  assert_output --partial "code_ref_checks — no data yet"
}

@test "tables absent: does NOT print green OK for honesty tables" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  # Do NOT create any of the four honesty tables

  _run_doctor

  # Must not report a clean OK for these tables (that would be the deep-research bug)
  refute_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "completeness_events — none in last 7d"
  refute_output --partial "agent_protocol_violations — none in last 7d"
  refute_output --partial "code_ref_checks — none in last 7d"
}

# ── Test 2: DB unreadable — cast.db is not a valid SQLite file ───────────────
@test "unreadable db: cast doctor does not crash and honesty block reports unavailable" {
  # Overwrite cast.db with a non-sqlite file
  echo "notadb" > "$CAST_DB_PATH"

  # cast doctor will fail the first db accessibility check, but should
  # exit cleanly (not crash with unhandled error)
  run bash "$CAST_BIN" doctor 2>&1

  # The command must complete (exit may be non-zero due to db check failing,
  # but it must not produce an uncaught error / crash exit > 1 from bash -e)
  # We check that the output contains an 'unavailable' or error message,
  # and that it does NOT contain the green OK honesty lines.
  refute_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "completeness_events — none in last 7d"
  # Output should mention cast.db is not accessible (from section 1 of doctor)
  assert_output --partial "cast.db not accessible"
}

# ── Test 3: Tables present, 0 rows — all-OK state ───────────────────────────
@test "present empty tables: reports OK 'none in last 7d' for each" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"
  # Tables exist but no rows inserted

  _run_doctor

  assert_output --partial "agent_hallucinations — none in last 7d"
  assert_output --partial "completeness_events — none in last 7d"
  assert_output --partial "agent_protocol_violations — none in last 7d"
  assert_output --partial "code_ref_checks — none in last 7d"
}

@test "present empty tables: does NOT show INFO 'no data yet'" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  _run_doctor

  refute_output --partial "agent_hallucinations — no data yet"
  refute_output --partial "completeness_events — no data yet"
  refute_output --partial "agent_protocol_violations — no data yet"
  refute_output --partial "code_ref_checks — no data yet"
}

# ── Test 4: Tables present and populated ────────────────────────────────────
@test "populated tables: reports WARN with count and per-agent breakdown" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Insert 2 hallucinations for code-writer (recent)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/some/file.ts', '[NOT FOUND]', 0, datetime('now', '-1 hour'));
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/other/file.ts', '[NOT FOUND]', 0, datetime('now', '-2 hours'));
SQL

  # Insert 1 completeness_event severity HIGH (recent)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO completeness_events (agent, truncated_at, snippet, severity)
VALUES ('debugger', datetime('now', '-30 minutes'), 'Status: ...', 'HIGH');
SQL

  _run_doctor

  # agent_hallucinations: 2 flagged, breakdown shows code-writer
  assert_output --partial "agent_hallucinations — 2 flagged"
  assert_output --partial "code-writer"

  # completeness_events: 1 flagged, HIGH severity
  assert_output --partial "completeness_events — 1 flagged"
  assert_output --partial "HIGH"
}

@test "populated hallucinations: does NOT report OK or 'none in last 7d'" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/some/file.ts', '[NOT FOUND]', 0, datetime('now', '-1 hour'));
SQL

  _run_doctor

  refute_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "agent_hallucinations — no data yet"
}

@test "old rows outside 7d window are ignored: reports none in last 7d" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Insert a hallucination 8 days ago — outside the 7d window
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/old/file.ts', '[NOT FOUND]', 0, datetime('now', '-8 days'));
SQL

  _run_doctor

  # Should show OK, not WARN — old row is outside the window
  assert_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "agent_hallucinations — 1 flagged"
}

# ── Test 5: silent truncations (maxTurns) — WARN path ───────────────────────
@test "silent truncations: WARN when stuck-running row older than 2h exists" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # The minimal DDL uses agent_name; add the production column names idempotently
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN agent TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN abandoned_at TEXT;" 2>/dev/null || true

  # Insert a row stuck in running state for 3h (pre-reaper, not yet abandoned)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (agent, started_at, status)
VALUES ('test-writer', datetime('now', '-3 hours'), 'running');
SQL

  _run_doctor

  assert_output --partial "silent truncations (maxTurns) — 1 suspected truncation(s)"
  assert_output --partial "test-writer"
  assert_output --partial "likely maxTurns cap hit"
}

# ── Test 6: silent truncations (maxTurns) — OK path ─────────────────────────
@test "silent truncations: OK when no qualifying rows exist" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Add production column names the minimal DDL omits (idempotent)
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN agent TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN abandoned_at TEXT;" 2>/dev/null || true

  # Insert a recent running row (only 30 minutes old — within the 2h threshold)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (agent, started_at, status)
VALUES ('code-writer', datetime('now', '-30 minutes'), 'running');
SQL

  _run_doctor

  assert_output --partial "silent truncations (maxTurns) — none in last 7d"
  refute_output --partial "silent truncations (maxTurns) — 1 suspected truncation"
}
