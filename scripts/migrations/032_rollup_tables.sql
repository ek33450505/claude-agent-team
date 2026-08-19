-- Migration 032: add agent_runs_daily + mcp_calls_daily pre-prune rollup tables (C5).
-- Finding: cast-db-prune.py deletes raw rows from agent_runs (started_at) and
--   routing_events (timestamp) on a rolling retention window with nothing aggregated
--   first, so cost/model/status and MCP-call trends are destroyed permanently once a
--   day ages out (the 2026-07-06 cost-audit figures are unreproducible for exactly this
--   reason). This migration provisions the two daily rollup tables written by the new
--   scripts/cast-db-rollup.py; wiring cast-db-rollup.py to run before cast-db-prune.py
--   is a separate change.
-- Mirrors the two CREATE TABLE + CREATE INDEX blocks added to cast-db-init.sh, which is
--   the SINGLE SOURCE OF TRUTH for fresh DBs (migrations do not run at install); this
--   migration backfills the same tables onto existing/legacy DBs.
-- Statements below are copied verbatim from cast-db-init.sh (same convention as
--   migrations 029/031) — keep the two surfaces in sync if either schema changes.
-- No defensive parent-table CREATE is needed here (unlike migration 031's agent_runs
--   guard): both tables are plain CREATE TABLE IF NOT EXISTS with no FK / dependency on
--   any other table, so cast-migrate.py's idempotency fallback has nothing to tolerate.

CREATE TABLE IF NOT EXISTS agent_runs_daily (
  day            TEXT NOT NULL,
  agent          TEXT NOT NULL DEFAULT '',
  model          TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT '',
  runs           INTEGER NOT NULL DEFAULT 0,
  with_response  INTEGER NOT NULL DEFAULT 0,
  input_tokens   INTEGER NOT NULL DEFAULT 0,
  output_tokens  INTEGER NOT NULL DEFAULT 0,
  cache_read_input_tokens     INTEGER NOT NULL DEFAULT 0,
  cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd       REAL    NOT NULL DEFAULT 0,
  duration_ms    INTEGER NOT NULL DEFAULT 0,
  tool_uses      INTEGER NOT NULL DEFAULT 0,
  rolled_up_at   TEXT    NOT NULL,
  PRIMARY KEY (day, agent, model, status)
);
CREATE INDEX IF NOT EXISTS idx_agent_runs_daily_day ON agent_runs_daily(day);

CREATE TABLE IF NOT EXISTS mcp_calls_daily (
  day            TEXT NOT NULL,
  mcp_server     TEXT NOT NULL DEFAULT '',
  mcp_tool       TEXT NOT NULL DEFAULT '',
  outcome        TEXT NOT NULL DEFAULT '',
  is_cloud_bound INTEGER NOT NULL DEFAULT 0,
  calls          INTEGER NOT NULL DEFAULT 0,
  result_bytes   INTEGER NOT NULL DEFAULT 0,
  rolled_up_at   TEXT    NOT NULL,
  PRIMARY KEY (day, mcp_server, mcp_tool, outcome, is_cloud_bound)
);
CREATE INDEX IF NOT EXISTS idx_mcp_calls_daily_day ON mcp_calls_daily(day);
