#!/bin/bash
# cast-db-init.sh — CAST SQLite State Foundation
# Creates ~/.claude/cast.db with the full schema for the CAST Local-First OS.
# Idempotent: uses CREATE TABLE IF NOT EXISTS; safe to run repeatedly.
# Schema versioning via PRAGMA user_version (current = 1).
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

# Check for sqlite3
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 not found in PATH. Install sqlite3 to use cast.db." >&2
  exit 1
fi

CURRENT_VERSION="$(sqlite3 "$DB_PATH" 'PRAGMA user_version;' 2>/dev/null || echo 0)"

if [ "$CURRENT_VERSION" -ge 1 ]; then
  echo "cast.db already initialized (v${CURRENT_VERSION})"
  exit 0
fi

sqlite3 "$DB_PATH" <<'SQL'
-- Sessions: one row per Claude Code session
CREATE TABLE IF NOT EXISTS sessions (
  id                    TEXT PRIMARY KEY,          -- CLAUDE_SESSION_ID
  project               TEXT,                      -- git repo name
  project_root          TEXT,                      -- absolute path to repo root
  started_at            TEXT,                      -- ISO8601
  ended_at              TEXT,
  total_input_tokens    INTEGER DEFAULT 0,
  total_output_tokens   INTEGER DEFAULT 0,
  total_cost_usd        REAL    DEFAULT 0.0,
  model                 TEXT                       -- primary model used
);

-- Agent runs: one row per agent invocation
CREATE TABLE IF NOT EXISTS agent_runs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT REFERENCES sessions(id),
  agent           TEXT NOT NULL,                   -- 'code-reviewer', 'debugger', etc.
  model           TEXT,                            -- 'cloud:sonnet', 'local:qwen3:8b'
  started_at      TEXT,
  ended_at        TEXT,
  status          TEXT,                            -- DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  cost_usd        REAL,
  task_summary    TEXT,                            -- first 200 chars of task
  prompt          TEXT,                            -- full prompt (optional, privacy flag)
  project         TEXT
);

-- Routing events: replaces routing-log.jsonl
CREATE TABLE IF NOT EXISTS routing_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  timestamp       TEXT,
  prompt_preview  TEXT,                            -- first 80 chars of prompt
  action          TEXT,                            -- matched | no_match | group_dispatched | loop_break
  matched_route   TEXT,
  match_type      TEXT,                            -- regex | semantic | group | catchall
  pattern         TEXT,
  confidence      TEXT,                            -- hard | soft | semantic
  project         TEXT
);

-- Persistent task queue: survives across sessions
CREATE TABLE IF NOT EXISTS task_queue (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at            TEXT,
  project               TEXT,
  project_root          TEXT,
  agent                 TEXT,
  task                  TEXT NOT NULL,
  priority              INTEGER DEFAULT 5,         -- 1=urgent, 10=low
  status                TEXT DEFAULT 'pending',    -- pending | claimed | done | failed
  claimed_at            TEXT,
  claimed_by_session    TEXT,
  completed_at          TEXT,
  result_summary        TEXT,
  retry_count           INTEGER DEFAULT 0,
  max_retries           INTEGER DEFAULT 3,
  scheduled_for         TEXT                       -- ISO8601, NULL = run immediately
);

-- Agent memories: replaces markdown MEMORY.md files for queryable state
CREATE TABLE IF NOT EXISTS agent_memories (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  agent       TEXT NOT NULL,
  project     TEXT,
  type        TEXT,                                -- user | feedback | project | reference
  name        TEXT,
  description TEXT,
  content     TEXT,
  created_at  TEXT,
  updated_at  TEXT,
  embedding   BLOB                                 -- sqlite-vec F32 embedding (nullable)
);

-- Cost budgets
CREATE TABLE IF NOT EXISTS budgets (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  scope         TEXT,                              -- session | project | global
  scope_key     TEXT,                              -- session_id | project_name | 'global'
  period        TEXT,                              -- daily | weekly | monthly | per-session
  limit_usd     REAL,
  alert_at_pct  REAL DEFAULT 0.80,                -- warn at 80% consumed
  created_at    TEXT
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_routing_events_session   ON routing_events(session_id);
CREATE INDEX IF NOT EXISTS idx_routing_events_timestamp ON routing_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_agent_runs_session       ON agent_runs(session_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent         ON agent_runs(agent);
CREATE INDEX IF NOT EXISTS idx_task_queue_status        ON task_queue(status);
CREATE INDEX IF NOT EXISTS idx_agent_memories_agent     ON agent_memories(agent);

-- Set schema version
PRAGMA user_version = 1;
SQL

echo "cast.db initialized (v1)"
