-- Migration 031: index agent_runs(started_at) for the 21-day cost-trend query.
-- Finding: cast-record-review.py's cost-trend query filters/sorts agent_runs by
--   started_at over a rolling 21-day window; PRAGMA index_list on agent_runs has no
--   index on started_at (only session_id, agent, status, agent_id, ended_at are
--   covered), forcing a full table scan on every weekly record-review run.
-- Mirrors the index statement added to cast-db-init.sh, which is the SINGLE SOURCE
--   OF TRUTH for fresh DBs (migrations do not run at install); this migration
--   backfills the same index onto existing/legacy DBs.
-- The IF-NOT-EXISTS table statement below (copied verbatim from cast-db-init.sh,
--   same convention as migration 029) is required because cast-migrate.py's
--   idempotency fallback tolerates "no such table" only for ALTER TABLE
--   ADD/DROP COLUMN and UPDATE/DELETE — NOT for CREATE INDEX (see
--   cast-migrate.py's _apply_migration_file docstring) — so a bare CREATE INDEX
--   would raise on a migrations-only test DB where agent_runs was never
--   provisioned. On the live DB agent_runs already exists, so this statement is
--   a no-op and only the index is actually created.

-- Ensure agent_runs exists before indexing it (schema copied verbatim from
-- cast-db-init.sh — keep in sync if either surface changes).
CREATE TABLE IF NOT EXISTS agent_runs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT REFERENCES sessions(id),
  agent           TEXT NOT NULL,
  model           TEXT,
  started_at      TEXT,
  ended_at        TEXT,
  status          TEXT,
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  cost_usd        REAL,
  agent_id        TEXT,
  response        TEXT,
  cache_read_input_tokens INTEGER,
  cache_creation_input_tokens INTEGER,
  duration_ms     INTEGER,
  tool_uses       INTEGER,
  files           TEXT,
  file_class      TEXT,
  abandoned_at    TIMESTAMP,
  branch          TEXT
);

CREATE INDEX IF NOT EXISTS idx_agent_runs_started_at ON agent_runs(started_at);
