#!/bin/bash
# cast-db-init.sh — CAST SQLite State Foundation (v8 — swarm tables)
# Creates ~/.claude/cast.db with core tables + swarm observability tables:
#   sessions, agent_runs, routing_events, agent_memories
#   swarm_sessions, teammate_runs, teammate_messages
#
# Idempotent: uses CREATE TABLE IF NOT EXISTS; safe to run repeatedly.
# Schema versioning via PRAGMA user_version (current = 8).
#
# KNOWN ORGANIC SCHEMA ADDITIONS (live DB may contain unprovisionable tables):
# These exist in deployed instances but are added by external systems or
# sessions outside this init script, and should NOT be included here:
#   - agent_memories_fts (FTS5 full-text search index)
#   - memory_decay_log (temporal decay tracking for memory expiry)
#   - agent_memory_embeddings (semantic search vectors)
# To audit live DB: sqlite3 ~/.claude/cast.db ".tables"
#
# Usage:
#   cast-db-init.sh [--db /path/to/cast.db]

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# Allow override via flag
if [ "${1:-}" = "--db" ] && [ -n "${2:-}" ]; then
  DB_PATH="$2"
fi

# Ensure parent directory exists
mkdir -p "$(dirname "$DB_PATH")"

# Harden permissions on existing DB
chmod 600 "$DB_PATH" 2>/dev/null || true

# Check for sqlite3
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 not found in PATH. Install sqlite3 to use cast.db." >&2
  exit 1
fi

CURRENT_VERSION="$(sqlite3 "$DB_PATH" 'PRAGMA user_version;' 2>/dev/null || echo 0)"

# If already at v8+, ensure all additive tables exist and exit
if [ "$CURRENT_VERSION" -ge 8 ]; then
  # Additive migration: create stream_events and stream_hook_events if missing
  # Also add model_used column to agent_runs if missing (Ollama contractor routing)
  # Also add cache token columns if missing (Task 0a: token optimization)
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN model_used TEXT;" 2>/dev/null || true
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN cache_read_input_tokens INTEGER;" 2>/dev/null || true
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN cache_creation_input_tokens INTEGER;" 2>/dev/null || true
  sqlite3 "$DB_PATH" <<'STREAM_TABLES'
CREATE TABLE IF NOT EXISTS stream_events (
  id                  TEXT PRIMARY KEY,
  session_id          TEXT,
  timestamp           TEXT,
  event_type          TEXT,
  tool_name           TEXT,
  tool_input_preview  TEXT,
  status              TEXT,
  duration_ms         INTEGER,
  raw_json            TEXT
);

CREATE TABLE IF NOT EXISTS stream_hook_events (
  id          TEXT PRIMARY KEY,
  session_id  TEXT,
  timestamp   TEXT,
  hook_type   TEXT,
  tool_name   TEXT,
  result      TEXT,
  duration_ms INTEGER,
  output      TEXT
);

CREATE INDEX IF NOT EXISTS idx_stream_events_session
  ON stream_events(session_id);
CREATE INDEX IF NOT EXISTS idx_stream_events_timestamp
  ON stream_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_stream_hook_events_session
  ON stream_hook_events(session_id);

CREATE TABLE IF NOT EXISTS swarm_sessions (
  id           TEXT PRIMARY KEY,
  team_name    TEXT NOT NULL,
  config_path  TEXT,
  started_at   TEXT,
  ended_at     TEXT,
  status       TEXT DEFAULT 'running',
  session_id   TEXT,
  project      TEXT,
  notes        TEXT
);

CREATE TABLE IF NOT EXISTS teammate_runs (
  id           TEXT PRIMARY KEY,
  swarm_id     TEXT REFERENCES swarm_sessions(id),
  agent_role   TEXT,
  agent_def    TEXT,
  worktree     TEXT,
  task_id      TEXT,
  task_subject TEXT,
  status       TEXT DEFAULT 'idle',
  started_at   TEXT,
  ended_at     TEXT,
  tokens_in    INTEGER DEFAULT 0,
  tokens_out   INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS teammate_messages (
  id           TEXT PRIMARY KEY,
  swarm_id     TEXT REFERENCES swarm_sessions(id),
  from_agent   TEXT,
  to_agent     TEXT,
  message_type TEXT,
  payload      TEXT,
  timestamp    TEXT
);

CREATE INDEX IF NOT EXISTS idx_teammate_runs_swarm ON teammate_runs(swarm_id);
CREATE INDEX IF NOT EXISTS idx_teammate_messages_swarm ON teammate_messages(swarm_id);
CREATE INDEX IF NOT EXISTS idx_swarm_sessions_team ON swarm_sessions(team_name);

-- Indexes added 2026-04-16 audit remediation
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);
CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON sessions(started_at);
CREATE INDEX IF NOT EXISTS idx_agent_runs_project ON agent_runs(project);
CREATE INDEX IF NOT EXISTS idx_routing_events_event_type ON routing_events(event_type);
STREAM_TABLES
  echo "cast.db already initialized (v${CURRENT_VERSION}), all tables ensured" >&2
  exit 0
fi

# Migrate v7 → v8: add swarm tables (additive only — no drops)
if [ "$CURRENT_VERSION" -eq 7 ]; then
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN model_used TEXT;" 2>/dev/null || true
  sqlite3 "$DB_PATH" <<'MIGRATE_V8'
CREATE TABLE IF NOT EXISTS stream_events (
  id                  TEXT PRIMARY KEY,
  session_id          TEXT,
  timestamp           TEXT,
  event_type          TEXT,
  tool_name           TEXT,
  tool_input_preview  TEXT,
  status              TEXT,
  duration_ms         INTEGER,
  raw_json            TEXT
);

CREATE TABLE IF NOT EXISTS stream_hook_events (
  id          TEXT PRIMARY KEY,
  session_id  TEXT,
  timestamp   TEXT,
  hook_type   TEXT,
  tool_name   TEXT,
  result      TEXT,
  duration_ms INTEGER,
  output      TEXT
);

CREATE INDEX IF NOT EXISTS idx_stream_events_session
  ON stream_events(session_id);
CREATE INDEX IF NOT EXISTS idx_stream_events_timestamp
  ON stream_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_stream_hook_events_session
  ON stream_hook_events(session_id);

CREATE TABLE IF NOT EXISTS swarm_sessions (
  id           TEXT PRIMARY KEY,
  team_name    TEXT NOT NULL,
  config_path  TEXT,
  started_at   TEXT,
  ended_at     TEXT,
  status       TEXT DEFAULT 'running',
  session_id   TEXT,
  project      TEXT,
  notes        TEXT
);

CREATE TABLE IF NOT EXISTS teammate_runs (
  id           TEXT PRIMARY KEY,
  swarm_id     TEXT REFERENCES swarm_sessions(id),
  agent_role   TEXT,
  agent_def    TEXT,
  worktree     TEXT,
  task_id      TEXT,
  task_subject TEXT,
  status       TEXT DEFAULT 'idle',
  started_at   TEXT,
  ended_at     TEXT,
  tokens_in    INTEGER DEFAULT 0,
  tokens_out   INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS teammate_messages (
  id           TEXT PRIMARY KEY,
  swarm_id     TEXT REFERENCES swarm_sessions(id),
  from_agent   TEXT,
  to_agent     TEXT,
  message_type TEXT,
  payload      TEXT,
  timestamp    TEXT
);

CREATE INDEX IF NOT EXISTS idx_teammate_runs_swarm ON teammate_runs(swarm_id);
CREATE INDEX IF NOT EXISTS idx_teammate_messages_swarm ON teammate_messages(swarm_id);
CREATE INDEX IF NOT EXISTS idx_swarm_sessions_team ON swarm_sessions(team_name);

-- Indexes added 2026-04-16 audit remediation
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);
CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON sessions(started_at);
CREATE INDEX IF NOT EXISTS idx_agent_runs_project ON agent_runs(project);
CREATE INDEX IF NOT EXISTS idx_routing_events_event_type ON routing_events(event_type);

PRAGMA user_version = 8;
MIGRATE_V8
  echo "cast.db migrated v7 → v8 (added swarm_sessions, teammate_runs, teammate_messages)" >&2
  CURRENT_VERSION=8
fi

# Migrate v6 → v7: drop empty tables, add batch_id to agent_runs
if [ "$CURRENT_VERSION" -eq 6 ]; then
  sqlite3 "$DB_PATH" <<'MIGRATE_V7'
DROP TABLE IF EXISTS task_queue;
DROP TABLE IF EXISTS budgets;
DROP TABLE IF EXISTS mismatch_signals;
DROP TABLE IF EXISTS quality_gates;
DROP TABLE IF EXISTS dispatch_decisions;

-- Add batch_id column if missing
ALTER TABLE agent_runs ADD COLUMN batch_id INTEGER;
-- Add model_used column if missing (Ollama contractor routing)
ALTER TABLE agent_runs ADD COLUMN model_used TEXT;
CREATE INDEX IF NOT EXISTS idx_agent_runs_batch_id ON agent_runs(batch_id);

-- Drop stale indexes
DROP INDEX IF EXISTS idx_task_queue_status;
DROP INDEX IF EXISTS idx_task_queue_created_at;
DROP INDEX IF EXISTS idx_budgets_scope_key;
DROP INDEX IF EXISTS idx_mismatch_signals_session;
DROP INDEX IF EXISTS idx_mismatch_signals_route;
DROP INDEX IF EXISTS idx_mismatch_signals_timestamp;
DROP INDEX IF EXISTS idx_quality_gates_session;
DROP INDEX IF EXISTS idx_quality_gates_gate_type;
DROP INDEX IF EXISTS idx_quality_gates_created_at;
DROP INDEX IF EXISTS idx_dispatch_decisions_session;
DROP INDEX IF EXISTS idx_dispatch_decisions_agent;
DROP INDEX IF EXISTS idx_dispatch_decisions_created_at;

PRAGMA user_version = 7;
MIGRATE_V7
  echo "cast.db migrated v6 → v7 (dropped 5 empty tables, added batch_id)" >&2
  CURRENT_VERSION=7
fi

# Fresh install (no existing DB or version 0-6)
if [ "$CURRENT_VERSION" -lt 7 ]; then
  sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys = ON;

-- Sessions: one row per Claude Code session
CREATE TABLE IF NOT EXISTS sessions (
  id                    TEXT PRIMARY KEY,
  project               TEXT,
  project_root          TEXT,
  started_at            TEXT,
  ended_at              TEXT,
  model                 TEXT
);

-- Agent runs: one row per agent invocation
CREATE TABLE IF NOT EXISTS agent_runs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT REFERENCES sessions(id),
  agent           TEXT NOT NULL,
  model           TEXT,
  started_at      TEXT,
  ended_at        TEXT,
  status          TEXT CHECK (status IN ('DONE','DONE_WITH_CONCERNS','BLOCKED','NEEDS_CONTEXT','running','failed')),
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  cost_usd        REAL,
  task_summary    TEXT,
  project         TEXT,
  agent_id        TEXT,
  batch_id        INTEGER,
  model_used      TEXT,
  response        TEXT,
  cache_read_input_tokens INTEGER,
  cache_creation_input_tokens INTEGER
);

-- Routing events: structured event log
CREATE TABLE IF NOT EXISTS routing_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  timestamp       TEXT,
  prompt_preview  TEXT,
  action          TEXT,
  matched_route   TEXT,
  match_type      TEXT,
  pattern         TEXT,
  confidence      TEXT,
  project         TEXT,
  event_type      TEXT,
  data            TEXT
);

-- Agent memories: queryable agent state
CREATE TABLE IF NOT EXISTS agent_memories (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  agent       TEXT NOT NULL,
  project     TEXT,
  type        TEXT,
  name        TEXT,
  description TEXT,
  content     TEXT,
  created_at  TEXT,
  updated_at  TEXT,
  confidence  REAL DEFAULT 1.0,
  importance  REAL DEFAULT 0.5,
  decay_rate  REAL DEFAULT 0.0,
  valid_from  TEXT,
  valid_to    TEXT,
  superseded_by INTEGER,
  source_type TEXT,
  embedding BLOB,
  last_validated_at TEXT
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_agent_runs_session       ON agent_runs(session_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent         ON agent_runs(agent);
CREATE INDEX IF NOT EXISTS idx_agent_runs_status        ON agent_runs(status);
CREATE INDEX IF NOT EXISTS idx_agent_runs_batch_id      ON agent_runs(batch_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent_id      ON agent_runs(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_ended_at      ON agent_runs(ended_at);
CREATE INDEX IF NOT EXISTS idx_routing_events_session   ON routing_events(session_id);
CREATE INDEX IF NOT EXISTS idx_routing_events_timestamp ON routing_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_routing_events_route     ON routing_events(matched_route);
CREATE INDEX IF NOT EXISTS idx_agent_memories_agent     ON agent_memories(agent);

-- Indexes added 2026-04-16 audit remediation
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);
CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON sessions(started_at);
CREATE INDEX IF NOT EXISTS idx_agent_runs_project ON agent_runs(project);
CREATE INDEX IF NOT EXISTS idx_routing_events_event_type ON routing_events(event_type);

-- Stream events: stream-JSON observability pipeline (v4.6)
CREATE TABLE IF NOT EXISTS stream_events (
  id                  TEXT PRIMARY KEY,
  session_id          TEXT,
  timestamp           TEXT,
  event_type          TEXT,
  tool_name           TEXT,
  tool_input_preview  TEXT,
  status              TEXT,
  duration_ms         INTEGER,
  raw_json            TEXT
);

CREATE TABLE IF NOT EXISTS stream_hook_events (
  id          TEXT PRIMARY KEY,
  session_id  TEXT,
  timestamp   TEXT,
  hook_type   TEXT,
  tool_name   TEXT,
  result      TEXT,
  duration_ms INTEGER,
  output      TEXT
);

CREATE INDEX IF NOT EXISTS idx_stream_events_session
  ON stream_events(session_id);
CREATE INDEX IF NOT EXISTS idx_stream_events_timestamp
  ON stream_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_stream_hook_events_session
  ON stream_hook_events(session_id);

-- Swarm observability tables (v8)
CREATE TABLE IF NOT EXISTS swarm_sessions (
  id           TEXT PRIMARY KEY,
  team_name    TEXT NOT NULL,
  config_path  TEXT,
  started_at   TEXT,
  ended_at     TEXT,
  status       TEXT DEFAULT 'running',
  session_id   TEXT,
  project      TEXT,
  notes        TEXT
);

CREATE TABLE IF NOT EXISTS teammate_runs (
  id           TEXT PRIMARY KEY,
  swarm_id     TEXT REFERENCES swarm_sessions(id),
  agent_role   TEXT,
  agent_def    TEXT,
  worktree     TEXT,
  task_id      TEXT,
  task_subject TEXT,
  status       TEXT DEFAULT 'idle',
  started_at   TEXT,
  ended_at     TEXT,
  tokens_in    INTEGER DEFAULT 0,
  tokens_out   INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS teammate_messages (
  id           TEXT PRIMARY KEY,
  swarm_id     TEXT REFERENCES swarm_sessions(id),
  from_agent   TEXT,
  to_agent     TEXT,
  message_type TEXT,
  payload      TEXT,
  timestamp    TEXT
);

CREATE INDEX IF NOT EXISTS idx_teammate_runs_swarm ON teammate_runs(swarm_id);
CREATE INDEX IF NOT EXISTS idx_teammate_messages_swarm ON teammate_messages(swarm_id);
CREATE INDEX IF NOT EXISTS idx_swarm_sessions_team ON swarm_sessions(team_name);

PRAGMA user_version = 8;
SQL
fi

chmod 600 "$DB_PATH"

# Enable WAL mode for concurrent write safety
sqlite3 "$DB_PATH" 'PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;' >/dev/null 2>&1 || true

# ===== SELF-HEALING SCHEMA BLOCK (runs unconditionally on every invocation) =====
# This block ensures critical columns exist in agent_runs, regardless of version history.
# It fixes DB instances that are at v8+ but missing columns due to prior failed migrations.
# Uses || true to make each ALTER idempotent (masks "duplicate column" SQLite errors).

_columns_added=0

# Check if agent_id column exists
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(agent_runs);" 2>/dev/null | grep -q "^[0-9].*agent_id"; then
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN agent_id TEXT;" 2>/dev/null || true
  _columns_added=1
fi

# Check if batch_id column exists
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(agent_runs);" 2>/dev/null | grep -q "^[0-9].*batch_id"; then
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN batch_id INTEGER;" 2>/dev/null || true
  _columns_added=1
fi

# Check if model_used column exists
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(agent_runs);" 2>/dev/null | grep -q "^[0-9].*model_used"; then
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN model_used TEXT;" 2>/dev/null || true
  _columns_added=1
fi

# Check if response column exists (migration 011 — agent response capture)
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(agent_runs);" 2>/dev/null | grep -q "^[0-9].*	response	"; then
  sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN response TEXT;" 2>/dev/null || true
  _columns_added=1
fi

# Check if agent_truncations table exists (migration 012 — agent truncation tracking)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "agent_truncations"; then
  sqlite3 "$DB_PATH" <<'AGENT_TRUNCATIONS_TABLE'
CREATE TABLE IF NOT EXISTS agent_truncations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT,
  agent_type   TEXT NOT NULL,
  agent_id     TEXT,
  batch_id     INTEGER,
  last_line    TEXT,
  timestamp    TEXT NOT NULL,
  char_count   INTEGER,
  has_status   INTEGER DEFAULT 0,
  has_json     INTEGER DEFAULT 0,
  partial_work_log TEXT
);

CREATE INDEX IF NOT EXISTS idx_at_session ON agent_truncations(session_id);
CREATE INDEX IF NOT EXISTS idx_at_agent_type ON agent_truncations(agent_type);
AGENT_TRUNCATIONS_TABLE
  _columns_added=1
fi

# Ensure batch_id and agent_id indexes exist
sqlite3 "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_agent_runs_batch_id ON agent_runs(batch_id);" 2>/dev/null || true
sqlite3 "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_agent_runs_agent_id ON agent_runs(agent_id);" 2>/dev/null || true

if [ "$_columns_added" -eq 1 ]; then
  echo "[cast-db-init] self-healed: added missing agent_id, batch_id, model_used, and/or response columns to agent_runs" >&2
fi

echo "cast.db initialized (v8, WAL mode, swarm tables included)" >&2
