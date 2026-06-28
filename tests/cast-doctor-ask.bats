#!/usr/bin/env bats
# Tests for cast doctor ask-record rung (A3 U6 "Ask-Your-Record")
# The ask-record rung reports on record_fts/record_embed indices

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# FTS5 availability check — skip tests if this build lacks FTS5
_fts5_ok() {
  printf 'CREATE VIRTUAL TABLE t USING fts5(x);' | sqlite3 ":memory:" >/dev/null 2>&1
}

# ── Minimal DDL to bootstrap cast.db for doctor ──────────────────────────────
_create_minimal_core_tables() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT, model TEXT, project_dir TEXT, session_type TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0.0, duration_ms INTEGER, tool_uses INTEGER DEFAULT 0, outcome TEXT);
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent TEXT, started_at TEXT, ended_at TEXT, status TEXT, duration_ms INTEGER, tool_uses INTEGER, outcome TEXT, response TEXT);
CREATE TABLE IF NOT EXISTS routing_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, matched_route TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT, project TEXT, type TEXT, name TEXT, description TEXT, content TEXT, confidence REAL DEFAULT 1.0, last_validated_at TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS stream_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS swarm_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, status TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS teammate_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, teammate_name TEXT, started_at TEXT, status TEXT);
CREATE TABLE IF NOT EXISTS teammate_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, role TEXT, content TEXT, ts TEXT);
CREATE TABLE IF NOT EXISTS tool_call_failures (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, tool_name TEXT, error TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_truncations (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT, truncated_at TEXT, severity TEXT, snippet TEXT);
CREATE TABLE IF NOT EXISTS injection_log (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, injected_at TEXT, source TEXT, content_preview TEXT);
CREATE TABLE IF NOT EXISTS quality_gates (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, gate_name TEXT, result TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS dispatch_decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent TEXT, reason TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS task_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, task_name TEXT, agent TEXT, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS routines (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, agent TEXT, schedule TEXT, status TEXT, last_run TEXT);
CREATE TABLE IF NOT EXISTS incidents (id TEXT PRIMARY KEY, occurred_at TEXT, problem_summary TEXT, fix_summary TEXT, related_files TEXT, related_commit TEXT, resolution_status TEXT, surfaced_by TEXT);
CREATE TABLE IF NOT EXISTS plan_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, plan_file TEXT, status TEXT, started_at TEXT, ended_at TEXT);
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ran_at TEXT, merged_count INTEGER, pruned_count INTEGER);
CREATE TABLE IF NOT EXISTS archived_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT, key TEXT, value TEXT, archived_at TEXT);
CREATE TABLE IF NOT EXISTS budgets (id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT, budget_usd REAL, spent_usd REAL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);
SQL
}

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_JOURNAL_DIR="$BATS_TEST_TMPDIR/journal"
  mkdir -p "$CAST_JOURNAL_DIR"
  export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$CLAUDE_PROJECTS_DIR"
  export CAST_AGENTS_DIR="$REPO_DIR/agents/core"
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  teardown_temp_home
}

# ── Test 1: record_fts absent — reports not present ──────────────────────────
@test "absent: reports record_fts not present" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  # Do NOT create record_fts table

  run bash "$CAST_BIN" doctor 2>&1

  assert_success
  assert_output --partial "ask-record: record_fts not present"
}

# ── Test 2: record_fts present, empty — reports present but empty ────────────
@test "present empty: reports present but empty" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  # Build full schema via cast-db-init.sh (creates record_fts with 0 rows)
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  run bash "$CAST_BIN" doctor 2>&1

  assert_success
  assert_output --partial "record_fts present but empty (0 rows)"
  refute_output --partial "rows indexed"
}

# ── Test 3: record_fts populated — reports row count and timestamp ───────────
@test "populated: reports rows indexed and newest timestamp" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  # Build full schema
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed an incident to populate record_fts via indexer
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary)
VALUES ('1', '2026-06-27T10:00:00Z', 'launchctl plist failed to load', 'fixed RunAtLoad');
SQL

  # Run the indexer to populate record_fts
  python3 "$REPO_DIR/scripts/cast-ask-index.py" >/dev/null 2>&1

  run bash "$CAST_BIN" doctor 2>&1

  assert_success
  assert_output --partial "rows indexed"
  assert_output --partial "newest"
}

# ── Test 4: record_embed absent/empty — reports semantic layer not populated ─
@test "honest degradation: empty record_embed shows not populated" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  # Build schema (creates record_embed but leaves it empty)
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  run bash "$CAST_BIN" doctor 2>&1

  assert_success
  assert_output --partial "ask-record: semantic layer not populated"
  refute_output --partial "record_embed"
}
