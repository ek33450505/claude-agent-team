#!/usr/bin/env bash
# cast-db-migrate-v32.sh — CAST DB migration v3.2
# Safely adds quality_gates and dispatch_decisions tables to an existing cast.db.
# Idempotent: uses CREATE TABLE IF NOT EXISTS — safe to run multiple times.
#
# Usage:
#   bash cast-db-migrate-v32.sh
#   CAST_DB=/path/to/cast.db bash cast-db-migrate-v32.sh

set -euo pipefail

DB="${CAST_DB:-${HOME}/.claude/cast.db}"

if [ ! -f "$DB" ]; then
  echo "Error: cast.db not found at $DB" >&2
  echo "Run cast-db-init.sh first to initialize the database." >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 not found in PATH." >&2
  exit 1
fi

sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS quality_gates (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  agent           TEXT,
  gate_type       TEXT,          -- 'code_review' | 'commit_approval' | 'teammate_idle'
  gate_result     TEXT,          -- 'pass' | 'block' | 'warn'
  feedback        TEXT,          -- feedback message when blocked
  artifact_count  INTEGER DEFAULT 0,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS dispatch_decisions (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  prompt_snippet  TEXT,          -- first 200 chars of routing prompt
  chosen_agent    TEXT,
  model           TEXT,
  effort          TEXT,
  wave_id         TEXT,          -- ADM wave identifier if in orchestrated run
  parallel        INTEGER DEFAULT 0,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_quality_gates_session    ON quality_gates(session_id);
CREATE INDEX IF NOT EXISTS idx_quality_gates_gate_type  ON quality_gates(gate_type);
CREATE INDEX IF NOT EXISTS idx_quality_gates_created_at ON quality_gates(created_at);
CREATE INDEX IF NOT EXISTS idx_dispatch_decisions_session     ON dispatch_decisions(session_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_decisions_agent       ON dispatch_decisions(chosen_agent);
CREATE INDEX IF NOT EXISTS idx_dispatch_decisions_created_at  ON dispatch_decisions(created_at);
SQL

echo "Migration v3.2 complete — quality_gates and dispatch_decisions tables ready." >&2
