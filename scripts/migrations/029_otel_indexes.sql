-- Migration 029: index the OTLP feed tables for query + retention performance (2026-07-04 audit)
-- Finding (audit 2026-07-04, exact dbstat evidence): on the live 209 MB cast.db, otel_events
--   is the single largest table (~125 MB / ~92k rows, ~60% of the DB) and otel_metrics is
--   ~15 MB / ~19k rows — yet PRAGMA index_list on both returned EMPTY. Every session_id
--   correlation, every received_at range scan (dashboard queries + the nightly
--   cast-db-prune.py retention window) forced a full table scan.
-- Adds covering indexes for the two hot access paths on each table: session_id (correlation)
--   and received_at (range scans / retention prune).
-- Mirrors the index statements added to cast-db-init.sh, which is the SINGLE SOURCE
--   OF TRUTH for fresh DBs (migrations do not run at install); this migration backfills the
--   same indexes onto existing/legacy DBs.
-- The IF-NOT-EXISTS table statements below (copied verbatim from cast-db-init.sh) are
--   required because a bare index build raises "no such table" — which cast-migrate.py does
--   NOT tolerate — on a DB where the otel tables were never provisioned (a migrations-only
--   test DB, or a pre-v9-B3 legacy DB the collector never touched). On the live DB the tables
--   already exist, so those statements are no-ops. IF NOT EXISTS keeps the whole file
--   idempotent and fresh-DB-safe; cast-migrate.py tolerates re-runs.

-- Ensure the OTLP feed tables exist before indexing them (schema copied verbatim from
-- cast-db-init.sh — keep in sync if either surface changes).
CREATE TABLE IF NOT EXISTS otel_metrics (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id     TEXT,
  metric_name    TEXT NOT NULL,
  value          REAL,
  unit           TEXT,
  attributes     TEXT,
  time_unix_nano INTEGER,
  received_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE IF NOT EXISTS otel_events (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id     TEXT,
  event_name     TEXT,
  prompt_id      TEXT,
  severity       TEXT,
  body           TEXT,
  time_unix_nano INTEGER,
  received_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Hot access paths: session_id correlation + received_at range/retention scans.
CREATE INDEX IF NOT EXISTS idx_otel_events_session   ON otel_events(session_id);
CREATE INDEX IF NOT EXISTS idx_otel_events_received  ON otel_events(received_at);
CREATE INDEX IF NOT EXISTS idx_otel_metrics_session  ON otel_metrics(session_id);
CREATE INDEX IF NOT EXISTS idx_otel_metrics_received ON otel_metrics(received_at);
