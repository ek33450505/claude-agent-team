#!/bin/bash
# cast-db-init.sh — CAST SQLite State Foundation
# Creates ~/.claude/cast.db with the full schema for the CAST Local-First OS.
# Idempotent: uses CREATE TABLE IF NOT EXISTS; safe to run repeatedly.
# Schema versioning via PRAGMA user_version (current = 2).
#
# sqlite-vec extension support (optional, graceful degradation if unavailable):
#   Install: pip install sqlite-vec   OR   brew install sqlite-vec
#   Provides cosine similarity search over agent_memories.embedding column.
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

# Harden permissions on existing DB (migration path for installs prior to 0600 fix)
chmod 600 "$DB_PATH" 2>/dev/null || true

# Check for sqlite3
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 not found in PATH. Install sqlite3 to use cast.db." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# cast_vec_available — returns 0 if sqlite-vec extension can be loaded, 1 if not
#
# Uses python3 sqlite3 module which supports load_extension() when the
# underlying SQLite library has extension loading enabled (default on macOS/Linux).
# ---------------------------------------------------------------------------
cast_vec_available() {
  python3 - <<'PYEOF' 2>/dev/null
import sqlite3, sys
conn = sqlite3.connect(":memory:")
conn.enable_load_extension(True)
try:
    conn.load_extension("sqlite_vec")
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
}

# Attempt to load sqlite-vec; warn on stderr but never block initialization
if cast_vec_available 2>/dev/null; then
  SQLITE_VEC_AVAILABLE=1
else
  SQLITE_VEC_AVAILABLE=0
  echo "Warning: sqlite-vec extension not available. Semantic search will fall back to full-text LIKE matching." >&2
  echo "  To enable: pip install sqlite-vec   OR   brew install sqlite-vec" >&2
fi

export SQLITE_VEC_AVAILABLE

CURRENT_VERSION="$(sqlite3 "$DB_PATH" 'PRAGMA user_version;' 2>/dev/null || echo 0)"

if [ "$CURRENT_VERSION" -ge 4 ]; then
  echo "cast.db already initialized (v${CURRENT_VERSION})" >&2
  exit 0
fi

# Migrate v1 → v2: bump PRAGMA user_version only (no schema changes needed for v2)
if [ "$CURRENT_VERSION" -eq 1 ]; then
  sqlite3 "$DB_PATH" 'PRAGMA user_version = 2;'
  echo "cast.db migrated v1 → v2 (sqlite-vec support marker added)" >&2
  CURRENT_VERSION=2
fi

# Migrate v2 → v3: add mismatch_signals table
if [ "$CURRENT_VERSION" -eq 2 ]; then
  sqlite3 "$DB_PATH" <<'MIGRATE_V3'
CREATE TABLE IF NOT EXISTS mismatch_signals (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  routing_event_id    INTEGER REFERENCES routing_events(id),
  session_id          TEXT,
  original_prompt     TEXT,
  follow_up_prompt    TEXT,
  timestamp           TEXT,
  route_fired         TEXT,
  auto_detected       INTEGER  DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_mismatch_signals_session    ON mismatch_signals(session_id);
CREATE INDEX IF NOT EXISTS idx_mismatch_signals_route      ON mismatch_signals(route_fired);
CREATE INDEX IF NOT EXISTS idx_mismatch_signals_timestamp  ON mismatch_signals(timestamp);

PRAGMA user_version = 3;
MIGRATE_V3
  echo "cast.db migrated v2 → v3 (mismatch_signals table added)" >&2
  CURRENT_VERSION=3
fi

# Migrate v3 → v4: add commit_sha column to agent_runs
if [ "$CURRENT_VERSION" -eq 3 ]; then
  sqlite3 "$DB_PATH" <<'MIGRATE_V4'
ALTER TABLE agent_runs ADD COLUMN commit_sha TEXT;
PRAGMA user_version = 4;
MIGRATE_V4
  echo "cast.db migrated v3 → v4 (commit_sha column added to agent_runs)" >&2
  CURRENT_VERSION=4
  exit 0
fi

sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys = ON;

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
  status          TEXT CHECK (status IN ('DONE','DONE_WITH_CONCERNS','BLOCKED','NEEDS_CONTEXT','running','failed')),
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  cost_usd        REAL,
  task_summary    TEXT,                            -- first 200 chars of task
  prompt          TEXT,                            -- full prompt (optional, privacy flag)
  project         TEXT,
  commit_sha      TEXT                             -- git commit SHA after agent completes (for rollback)
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
  priority              INTEGER CHECK (priority BETWEEN 1 AND 10) DEFAULT 5,
  status                TEXT    CHECK (status IN ('pending','claimed','done','failed','cancelled')) DEFAULT 'pending',
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

-- Mismatch signals: rapid re-prompt after a route fired = potential route error
CREATE TABLE IF NOT EXISTS mismatch_signals (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  routing_event_id    INTEGER REFERENCES routing_events(id),
  session_id          TEXT,
  original_prompt     TEXT,    -- first 200 chars of the routed prompt
  follow_up_prompt    TEXT,    -- first 200 chars of the re-prompt
  timestamp           TEXT,    -- ISO8601
  route_fired         TEXT,    -- matched_route from the routing_event
  auto_detected       INTEGER  DEFAULT 1  -- 1 = auto, 0 = manually tagged
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_routing_events_session   ON routing_events(session_id);
CREATE INDEX IF NOT EXISTS idx_routing_events_timestamp ON routing_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_agent_runs_session       ON agent_runs(session_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent         ON agent_runs(agent);
CREATE INDEX IF NOT EXISTS idx_task_queue_status        ON task_queue(status);
CREATE INDEX IF NOT EXISTS idx_agent_memories_agent     ON agent_memories(agent);

CREATE INDEX IF NOT EXISTS idx_agent_runs_status        ON agent_runs(status);
CREATE INDEX IF NOT EXISTS idx_agent_runs_ended_at      ON agent_runs(ended_at);
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent_status  ON agent_runs(agent, status);
CREATE INDEX IF NOT EXISTS idx_task_queue_created_at    ON task_queue(created_at);
CREATE INDEX IF NOT EXISTS idx_routing_events_route     ON routing_events(matched_route);
CREATE INDEX IF NOT EXISTS idx_budgets_scope_key        ON budgets(scope_key);
CREATE INDEX IF NOT EXISTS idx_mismatch_signals_session    ON mismatch_signals(session_id);
CREATE INDEX IF NOT EXISTS idx_mismatch_signals_route      ON mismatch_signals(route_fired);
CREATE INDEX IF NOT EXISTS idx_mismatch_signals_timestamp  ON mismatch_signals(timestamp);

-- Set schema version
PRAGMA user_version = 4;
SQL

chmod 600 "$DB_PATH"
echo "cast.db initialized (v4)" >&2
