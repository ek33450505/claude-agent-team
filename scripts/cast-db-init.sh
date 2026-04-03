#!/bin/bash
# cast-db-init.sh — CAST SQLite State Foundation (v7 — clean rebuild)
# Creates ~/.claude/cast.db with exactly 4 tables:
#   sessions, agent_runs, routing_events, agent_memories
#
# Idempotent: uses CREATE TABLE IF NOT EXISTS; safe to run repeatedly.
# Schema versioning via PRAGMA user_version (current = 7).
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

# If already at v7, nothing to do
if [ "$CURRENT_VERSION" -ge 7 ]; then
  echo "cast.db already initialized (v${CURRENT_VERSION})" >&2
  exit 0
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

# Fresh install (no existing DB or version 0)
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
  batch_id        INTEGER
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
  updated_at  TEXT
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

PRAGMA user_version = 7;
SQL
fi

chmod 600 "$DB_PATH"

# Enable WAL mode for concurrent write safety
sqlite3 "$DB_PATH" 'PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;' >/dev/null 2>&1 || true

echo "cast.db initialized (v7, WAL mode, 4 tables)" >&2
