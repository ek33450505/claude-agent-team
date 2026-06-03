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

# If already at v8+, ensure version-specific additive tables exist, then FALL THROUGH
# to the unconditional self-healing block at the bottom (do NOT exit here).
if [ "$CURRENT_VERSION" -ge 8 ]; then
  # Additive migration: create stream_events if missing (stream_hook_events retired via migration 015)
  # Also add cache token columns if missing (Task 0a: token optimization)
  # Note: model_used column was dropped via migration 014 (audit 2026-05-16 #3)
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

CREATE INDEX IF NOT EXISTS idx_stream_events_session
  ON stream_events(session_id);
CREATE INDEX IF NOT EXISTS idx_stream_events_timestamp
  ON stream_events(timestamp);

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

CREATE TABLE IF NOT EXISTS tool_call_failures (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp  TEXT    NOT NULL,
    session_id TEXT,
    tool_name  TEXT    NOT NULL,
    error      TEXT,
    project    TEXT,
    data       TEXT
);

STREAM_TABLES
  # Phase 3 #1 fix: do NOT exit here. Falling through lets the unconditional
  # self-healing block (bottom of file) provision agent_truncations / injection_log /
  # quality_gates / dispatch_decisions / task_queue on EXISTING v8 DBs. The early
  # `exit 0` that used to be here made that block unreachable, so consolidated tables
  # were never created on any v8 DB (only on fresh installs, which fall through). The
  # version-gated migration blocks below are guarded by exact-version checks
  # (==7, ==6, <7) and will not fire for a v8 DB; every statement is idempotent.
  echo "cast.db already at v${CURRENT_VERSION}; ensuring additive + self-healing tables" >&2
fi

# Migrate v7 → v8: add swarm tables (additive only — no drops)
# Note: model_used column was dropped via migration 014 (audit 2026-05-16 #3)
if [ "$CURRENT_VERSION" -eq 7 ]; then
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

CREATE INDEX IF NOT EXISTS idx_stream_events_session
  ON stream_events(session_id);
CREATE INDEX IF NOT EXISTS idx_stream_events_timestamp
  ON stream_events(timestamp);

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

-- Tool call failures: PostToolUseFailure hook events (separate from routing_events)
CREATE TABLE IF NOT EXISTS tool_call_failures (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp  TEXT    NOT NULL,
    session_id TEXT,
    tool_name  TEXT    NOT NULL,
    error      TEXT,
    project    TEXT,
    data       TEXT
);

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
-- Note: model_used column dropped via migration 014 (audit 2026-05-16 #3)
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
  model                 TEXT,
  status                TEXT,
  deleted_at            TEXT,
  total_input_tokens    INTEGER,
  total_output_tokens   INTEGER,
  total_cost_usd        REAL
);

-- Agent runs: one row per agent invocation
CREATE TABLE IF NOT EXISTS agent_runs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT REFERENCES sessions(id),
  agent           TEXT NOT NULL,
  model           TEXT,
  started_at      TEXT,
  ended_at        TEXT,
  status          TEXT,  -- no CHECK: agent_runs is observability; the status contract is enforced by hooks/agents, not the DB (Phase 3). Writers also record 'abandoned','fallback','unknown'.
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  cost_usd        REAL,
  task_summary    TEXT,
  project         TEXT,
  agent_id        TEXT,
  batch_id        INTEGER,
  response        TEXT,
  cache_read_input_tokens INTEGER,
  cache_creation_input_tokens INTEGER,
  owns_files      TEXT
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
  data            TEXT,
  agent_id        TEXT,
  agent_type      TEXT
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
  last_validated_at TEXT,
  retrieval_count INTEGER DEFAULT 0
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

CREATE INDEX IF NOT EXISTS idx_stream_events_session
  ON stream_events(session_id);
CREATE INDEX IF NOT EXISTS idx_stream_events_timestamp
  ON stream_events(timestamp);

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

-- Tool call failures: PostToolUseFailure hook events (separate from routing_events)
CREATE TABLE IF NOT EXISTS tool_call_failures (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp  TEXT    NOT NULL,
    session_id TEXT,
    tool_name  TEXT    NOT NULL,
    error      TEXT,
    project    TEXT,
    data       TEXT
);

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

# model_used column was dropped via migration 014 (audit 2026-05-16 #3)
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

# injection_log: memory retrieval telemetry (writer: cast-memory-router.py)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "injection_log"; then
  sqlite3 "$DB_PATH" <<'INJECTION_LOG_TABLE'
CREATE TABLE IF NOT EXISTS injection_log (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  prompt_hash     TEXT,
  fact_id         INTEGER,
  score           REAL,
  score_breakdown TEXT,
  injected_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_injection_log_session     ON injection_log(session_id);
CREATE INDEX IF NOT EXISTS idx_injection_log_injected_at ON injection_log(injected_at);
INJECTION_LOG_TABLE
  _columns_added=1
fi

# quality_gates: per-agent contract compliance (writers: cast-subagent-stop-hook.sh, cast-no-fake-success-guard.sh)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "quality_gates"; then
  sqlite3 "$DB_PATH" <<'QUALITY_GATES_TABLE'
CREATE TABLE IF NOT EXISTS quality_gates (
  id              TEXT PRIMARY KEY,
  session_id      TEXT,
  batch_id        INTEGER,
  agent_name      TEXT,
  timestamp       TEXT,
  status_line     TEXT,
  contract_passed INTEGER,
  retry_count     INTEGER,
  gate_type       TEXT,
  created_at      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_quality_gates_session    ON quality_gates(session_id);
CREATE INDEX IF NOT EXISTS idx_quality_gates_gate_type  ON quality_gates(gate_type);
CREATE INDEX IF NOT EXISTS idx_quality_gates_created_at ON quality_gates(created_at);
QUALITY_GATES_TABLE
  _columns_added=1
fi

# dispatch_decisions: routing telemetry (writer: cast-session-end.sh, cast-subagent-stop-hook.sh)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "dispatch_decisions"; then
  sqlite3 "$DB_PATH" <<'DISPATCH_DECISIONS_TABLE'
CREATE TABLE IF NOT EXISTS dispatch_decisions (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  prompt_snippet  TEXT,
  chosen_agent    TEXT,
  model           TEXT,
  effort          TEXT,
  wave_id         TEXT,
  parallel        INTEGER DEFAULT 0,
  created_at      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_dispatch_decisions_session    ON dispatch_decisions(session_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_decisions_agent      ON dispatch_decisions(chosen_agent);
CREATE INDEX IF NOT EXISTS idx_dispatch_decisions_created_at ON dispatch_decisions(created_at);
DISPATCH_DECISIONS_TABLE
  _columns_added=1
fi

# task_queue: persistent agent task queue (writers: cast-queue-add.sh, cast-task-created-hook.sh)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "task_queue"; then
  sqlite3 "$DB_PATH" <<'TASK_QUEUE_TABLE'
CREATE TABLE IF NOT EXISTS task_queue (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  agent         TEXT NOT NULL,
  task          TEXT NOT NULL,
  priority      INTEGER DEFAULT 5,
  status        TEXT DEFAULT 'pending',
  created_at    TEXT DEFAULT (datetime('now')),
  claimed_at    TEXT,
  completed_at  TEXT,
  retry_count   INTEGER DEFAULT 0,
  max_retries   INTEGER DEFAULT 3,
  project       TEXT,
  project_root  TEXT,
  scheduled_for TEXT
);
CREATE INDEX IF NOT EXISTS idx_task_queue_status     ON task_queue(status);
CREATE INDEX IF NOT EXISTS idx_task_queue_created_at ON task_queue(created_at);
TASK_QUEUE_TABLE
  _columns_added=1
fi

# ── Phase 3: additive columns on core tables (idempotent; duplicate-column errors suppressed) ──
# agent_runs.owns_files — agent file-scope tracking (reader: cast-post-tool.py). Was provisioned
# only by the orphaned scripts/migrations/009, which never runs in the runtime.
sqlite3 "$DB_PATH" "ALTER TABLE agent_runs ADD COLUMN owns_files TEXT;" 2>/dev/null || true

# sessions cost-rollup + lifecycle columns (writers: cast-session-end.sh, cast-maintenance.sh,
# cast-budget-alert.sh, cast-cache-metrics.sh). Their UPDATEs failed on fresh installs without these.
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN status TEXT;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN deleted_at TEXT;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN total_input_tokens INTEGER;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN total_output_tokens INTEGER;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN total_cost_usd REAL;" 2>/dev/null || true

# routing_events agent-attribution columns (writer: cast-db-log.py INSERTs them).
sqlite3 "$DB_PATH" "ALTER TABLE routing_events ADD COLUMN agent_id TEXT;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE routing_events ADD COLUMN agent_type TEXT;" 2>/dev/null || true

# ── Phase 3: provision tables that have live writers but were only created by the now-defunct
# migration runners. cast-db-init.sh is the single source of truth (migrations don't run at install). ──

# routines: scheduled-agent definitions (writer: cast-db-routines.py)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "routines"; then
  sqlite3 "$DB_PATH" <<'ROUTINES_TABLE'
CREATE TABLE IF NOT EXISTS routines (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  trigger_type TEXT NOT NULL,
  trigger_value TEXT,
  agent_to_dispatch TEXT NOT NULL,
  prompt_template TEXT NOT NULL,
  output_dir TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_run_at TEXT,
  last_run_status TEXT,
  last_run_output_path TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_routines_name ON routines(name);
CREATE INDEX IF NOT EXISTS idx_routines_trigger ON routines(trigger_type, enabled);
ROUTINES_TABLE
  _columns_added=1
fi

# incidents: incident log (writers: cast-incident-record.sh, cast-incidents-backfill.py)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "incidents"; then
  sqlite3 "$DB_PATH" <<'INCIDENTS_TABLE'
CREATE TABLE IF NOT EXISTS incidents (
  id TEXT PRIMARY KEY,
  occurred_at TEXT NOT NULL,
  problem_summary TEXT NOT NULL,
  fix_summary TEXT,
  related_files TEXT,
  related_commit TEXT,
  resolution_status TEXT,
  surfaced_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_incidents_occurred ON incidents(occurred_at);
INCIDENTS_TABLE
  _columns_added=1
fi

# plan_sessions: links an orchestrate session to its plan file (writer: orchestrate skill)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "plan_sessions"; then
  sqlite3 "$DB_PATH" <<'PLAN_SESSIONS_TABLE'
CREATE TABLE IF NOT EXISTS plan_sessions (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  plan_file  TEXT NOT NULL,
  started_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_plan_sessions_session ON plan_sessions(session_id);
PLAN_SESSIONS_TABLE
  _columns_added=1
fi

# memory_consolidation_runs: "dream" consolidation telemetry (writers: cast-memory-dream*.py)
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "memory_consolidation_runs"; then
  sqlite3 "$DB_PATH" <<'MEM_CONSOLIDATION_TABLE'
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id              TEXT NOT NULL UNIQUE,
  project_id          TEXT NOT NULL,
  status              TEXT NOT NULL DEFAULT 'pending',
  instructions        TEXT,
  input_fingerprint   TEXT,
  output_path         TEXT,
  error               TEXT,
  started_at          TEXT,
  completed_at        TEXT,
  memory_files_read   INTEGER DEFAULT 0,
  transcripts_scanned INTEGER DEFAULT 0,
  candidates_written  INTEGER DEFAULT 0,
  created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_mcr_status ON memory_consolidation_runs(status);
MEM_CONSOLIDATION_TABLE
  _columns_added=1
fi

# archived_memories: low-importance memories moved out of agent_memories (writer: cast-memory-consolidate.py).
# Mirrors agent_memories columns + archived_at; the writer copies whatever columns intersect.
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "archived_memories"; then
  sqlite3 "$DB_PATH" <<'ARCHIVED_MEMORIES_TABLE'
CREATE TABLE IF NOT EXISTS archived_memories (
  id          INTEGER PRIMARY KEY,
  agent       TEXT,
  project     TEXT,
  type        TEXT,
  name        TEXT,
  description TEXT,
  content     TEXT,
  created_at  TEXT,
  updated_at  TEXT,
  confidence  REAL,
  importance  REAL,
  decay_rate  REAL,
  valid_from  TEXT,
  valid_to    TEXT,
  superseded_by INTEGER,
  source_type TEXT,
  embedding   BLOB,
  last_validated_at TEXT,
  retrieval_count INTEGER,
  archived_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_archived_memories_agent ON archived_memories(agent);
ARCHIVED_MEMORIES_TABLE
  _columns_added=1
fi

# budgets: per-scope cost limits (reader: cast-budget-alert.sh; writer: `cast budget set`).
# Was DROPPED in the v6→v7 migration and never re-provisioned.
if ! sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -q "budgets"; then
  sqlite3 "$DB_PATH" <<'BUDGETS_TABLE'
CREATE TABLE IF NOT EXISTS budgets (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  scope        TEXT,
  scope_key    TEXT,
  period       TEXT,
  limit_usd    REAL,
  alert_at_pct REAL,
  created_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_budgets_scope ON budgets(scope, period);
BUDGETS_TABLE
  _columns_added=1
fi

# Ensure batch_id and agent_id indexes exist
sqlite3 "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_agent_runs_batch_id ON agent_runs(batch_id);" 2>/dev/null || true
sqlite3 "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_agent_runs_agent_id ON agent_runs(agent_id);" 2>/dev/null || true

# Phase 3: drop the legacy agent_runs.status CHECK on existing DBs. The enum
# rejected real telemetry values ('abandoned','fallback','unknown') that wired
# writers produce, silently dropping rows. Idempotent helper — preserves all
# columns, data, the session_id FK, and every index; no-op when no CHECK exists.
_DROP_CHECK_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/cast-db-drop-status-check.py"
if [ -f "$_DROP_CHECK_HELPER" ] && command -v python3 >/dev/null 2>&1; then
  CAST_DB_PATH="$DB_PATH" python3 "$_DROP_CHECK_HELPER" "$DB_PATH" >&2 || true
fi

if [ "$_columns_added" -eq 1 ]; then
  echo "[cast-db-init] self-healed: added missing agent_id, batch_id, and/or response columns to agent_runs" >&2
fi

echo "cast.db initialized (v8, WAL mode, swarm tables included)" >&2
