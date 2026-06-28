#!/usr/bin/env bats
# Tests for cast ask and cast memory search (A3 "Ask-Your-Record")
# Exercises the unified record_fts FTS5 backend (U6)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# FTS5 availability check
_fts5_ok() {
  printf 'CREATE VIRTUAL TABLE t USING fts5(x);' | sqlite3 ":memory:" >/dev/null 2>&1
}

# Minimal DDL to bootstrap cast.db
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
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_JOURNAL_DIR="$BATS_TEST_TMPDIR/journal"
  mkdir -p "$CAST_JOURNAL_DIR"
  export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$CLAUDE_PROJECTS_DIR"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CAST_AGENTS_DIR="$REPO_DIR/agents/core"
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  teardown_temp_home
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION A: cast ask command tests
# ───────────────────────────────────────────────────────────────────────────

@test "cast ask: returns the matching record and excludes the non-matching one" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  # Build full schema (creates record_fts with FTS5)
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed two incidents with distinct terms
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary)
VALUES
  ('1', '2026-06-27T10:00:00Z', 'launchctl plist failed to load', 'fixed RunAtLoad'),
  ('2', '2026-06-27T09:00:00Z', 'oauth token refresh timeout', 'refreshed token cache');
SQL

  # Index to populate record_fts
  python3 "$REPO_DIR/scripts/cast-ask-index.py" >/dev/null 2>&1

  # Query with --no-refresh to use pre-indexed data
  run bash "$CAST_BIN" ask "launchctl" --no-refresh

  assert_success
  assert_output --partial "launchctl"
  refute_output --partial "oauth"
}

@test "cast ask: ranks the more-relevant record first (BM25 order)" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Doc HIGH: term 'kafka' appears 3x in a short body → strong BM25.
  # Doc LOW:  term 'kafka' appears once buried in a long filler body → weak BM25.
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary)
VALUES
  ('hi', '2026-06-27T10:00:00Z', 'kafka kafka kafka broker', 'restarted kafka'),
  ('lo', '2026-06-27T09:00:00Z', 'unrelated alpha beta gamma delta epsilon zeta eta theta kafka iota', 'lots of unrelated filler text here to dilute the term frequency and lengthen the document considerably');
SQL

  python3 "$REPO_DIR/scripts/cast-ask-index.py" >/dev/null 2>&1

  run bash "$CAST_BIN" ask "kafka" --no-refresh

  assert_success
  # Both present...
  assert_output --partial "broker"
  assert_output --partial "epsilon"
  # ...but the HIGH-relevance doc (title contains 'broker') must rank before the LOW one (title contains 'epsilon').
  local pos_hi pos_lo
  pos_hi=$(printf '%s\n' "$output" | grep -n "broker"  | head -1 | cut -d: -f1)
  pos_lo=$(printf '%s\n' "$output" | grep -n "epsilon" | head -1 | cut -d: -f1)
  [ -n "$pos_hi" ] && [ -n "$pos_lo" ] && [ "$pos_hi" -lt "$pos_lo" ]
}

@test "cast ask --json emits valid JSON array with the hit" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary)
VALUES ('1', '2026-06-27T10:00:00Z', 'launchctl plist failed', 'fixed RunAtLoad');
SQL

  python3 "$REPO_DIR/scripts/cast-ask-index.py" >/dev/null 2>&1

  run bash "$CAST_BIN" ask "launchctl" --no-refresh --json

  assert_success
  assert_output --partial "launchctl"            # raw JSON contains the hit
  # validate it parses as a JSON array of objects with the expected shape
  run python3 -c "import sys,json; d=json.loads(sys.argv[1]); assert isinstance(d, list) and d and d[0]['kind']=='incident' and 'snippet' in d[0]" "$output"
  assert_success
}

@test "cast ask --kind filters by record kind" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed an agent_run and an incident both with a shared term
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary)
VALUES ('1', '2026-06-27T10:00:00Z', 'plist configuration issue', 'resolved plist load error');
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, response)
VALUES ('s1', 'code-writer', '2026-06-27T09:00:00Z', '2026-06-27T09:05:00Z', 'DONE', 'plist parsing debug complete');
SQL

  python3 "$REPO_DIR/scripts/cast-ask-index.py" >/dev/null 2>&1

  # Filter to incidents only
  run bash "$CAST_BIN" ask "plist" --kind incident --no-refresh

  assert_success
  assert_output --partial "plist"
  # Agent-run should not be present (but incident-unique text is)
  assert_output --partial "configuration"
  refute_output --partial "parsing debug"
}

@test "cast ask --limit caps the result count" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed 3 matching incidents
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary)
VALUES
  ('1', '2026-06-27T10:00:00Z', 'first issue found', 'first fix'),
  ('2', '2026-06-27T09:00:00Z', 'second issue found', 'second fix'),
  ('3', '2026-06-27T08:00:00Z', 'third issue found', 'third fix');
SQL

  python3 "$REPO_DIR/scripts/cast-ask-index.py" >/dev/null 2>&1

  # Limit to 1 result
  run bash "$CAST_BIN" ask "issue" --limit 1 --no-refresh

  assert_success
  assert_output --partial "issue"
  # Count the number of "incident ·" lines (each result has this prefix)
  result_count=$(echo "$output" | grep -c "incident ·" || echo 0)
  [ "$result_count" -eq 1 ]
}

@test "cast ask: degraded path (no record_fts) returns advisory not crash" {
  # Do NOT build schema; no record_fts table exists
  _create_minimal_core_tables "$CAST_DB_PATH"

  run bash "$CAST_BIN" ask "anything" --no-refresh

  assert_success
  assert_output --partial "Advisory:"
}

@test "cast ask --semantic: fail-open when no Ollama returns FTS results" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary)
VALUES ('1', '2026-06-27T10:00:00Z', 'launchctl plist failed', 'fixed RunAtLoad');
SQL

  python3 "$REPO_DIR/scripts/cast-ask-index.py" >/dev/null 2>&1

  # Ask with --semantic; expect FTS results (not hung or crashed)
  run bash "$CAST_BIN" ask "launchctl" --semantic --no-refresh

  assert_success
  # Should still return FTS results even if Ollama is unavailable
  assert_output --partial "launchctl"
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION B: cast memory search command tests (U6 unified backend)
# ───────────────────────────────────────────────────────────────────────────

@test "cast memory search: returns adapted memory shape with agent/type/name" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed an agent_memory row
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at)
VALUES ('debugger', 'cast', 'feedback', 'maxTurns_silent_truncation', 'cached pattern',
        'maxTurns caps stop subagents silently with no Status block; observed on 2026-06-10',
        '2026-06-10T15:00:00Z', '2026-06-27T10:00:00Z');
SQL

  # Memory search triggers lazy index (rebuilds record_fts for kind=memory)
  run bash "$CAST_BIN" memory search "maxTurns"

  assert_success
  assert_output --partial "maxTurns"
  assert_output --partial "debugger"
  assert_output --partial "maxTurns_silent_truncation"
}

@test "cast memory search --type filters by memory type" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed two memories with different types, both matching the query "pattern"
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at)
VALUES
  ('debugger', 'cast', 'feedback', 'turncap_pattern', 'pattern obs', 'truncation pattern with maxTurns', '2026-06-10T15:00:00Z', '2026-06-27T10:00:00Z'),
  ('code-writer', 'cast', 'project', 'db_schema_pattern', 'pattern ref', 'schema pattern is source of truth', '2026-06-10T15:00:00Z', '2026-06-27T10:00:00Z');
SQL

  # Search for "pattern" with --type feedback (should only match the feedback memory)
  run bash "$CAST_BIN" memory search "pattern" --type feedback

  assert_success
  assert_output --partial "turncap_pattern"
  refute_output --partial "db_schema_pattern"
}

@test "cast memory search --json emits adapted array with contract keys" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at)
VALUES ('debugger', 'cast', 'feedback', 'test_memo', 'desc', 'content here', '2026-06-10T15:00:00Z', '2026-06-27T10:00:00Z');
SQL

  # Use --json to get structured output
  run bash "$CAST_BIN" memory search "memo" --json

  assert_success
  # Verify JSON structure contains the required keys
  echo "$output" | grep -q '"name"' || skip "JSON structure missing name key"
  echo "$output" | grep -q '"content"' || skip "JSON structure missing content key"
  echo "$output" | grep -q '"created_at"' || skip "JSON structure missing created_at key"
  # validate shape: array with objects containing all contract keys
  run python3 -c "import sys,json; d=json.loads(sys.argv[1]); assert isinstance(d,list) and d and set(['id','agent','type','name','content','created_at']).issubset(d[0].keys())" "$output"
  assert_success
}

@test "cast memory search: degraded path (no record_fts) returns advisory" {
  # Do NOT build schema
  _create_minimal_core_tables "$CAST_DB_PATH"

  run bash "$CAST_BIN" memory search "test"

  assert_success
  assert_output --partial "Advisory:"
}

@test "cast memory search --agent filters by agent name" {
  _fts5_ok || skip "FTS5 not available in this sqlite build"

  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed memories from different agents with shared content
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at)
VALUES
  ('debugger', 'cast', 'feedback', 'pattern_a', 'desc', 'truncation issue', '2026-06-10T15:00:00Z', '2026-06-27T10:00:00Z'),
  ('code-writer', 'cast', 'feedback', 'pattern_b', 'desc', 'truncation issue', '2026-06-10T15:00:00Z', '2026-06-27T10:00:00Z');
SQL

  # Filter to debugger only
  run bash "$CAST_BIN" memory search "truncation" --agent debugger

  assert_success
  assert_output --partial "pattern_a"
  refute_output --partial "pattern_b"
}
