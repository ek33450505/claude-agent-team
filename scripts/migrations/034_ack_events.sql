-- Migration 034: add ack_events table (CAST v10 I-3a, part 1).
-- Finding: CAST has ~19 hand-rolled escape hatches (CAST_COMMIT_AGENT=1,
--   CAST_PUSH_OK=1, and siblings) scattered across pre-tool guards and
--   agent scripts. Every one of them silently allows the bypassed operation
--   and records NOTHING — there is no way for `cast ask` to answer "who
--   bypassed which gate, when, and why." This migration provisions the
--   PRIMITIVE half of the fix: a single table that scripts/cast_ack.py's
--   record_ack() writes to, one row per hatch use.
-- Design contract (Ed, 2026-08-24): accept ANY non-empty value, including a
--   bare "=1" — no reason string is required, so existing callers keep
--   working unmodified. has_reason=0 marks a bare/truthy value ("1",
--   "true", "yes") that carries no human explanation; has_reason=1 marks
--   anything else, stored verbatim (sanitized + truncated to 500 chars) in
--   `value`. Recording is best-effort by construction: cast_ack.py wraps
--   every path in try/except and the CLI entrypoint always exits 0, so a
--   DB write failure here can never change whether a gate passes.
-- This part builds the primitive + schema only — wiring the 19 callers to
--   actually invoke cast_ack.py is a SEPARATE unit. No caller writes to
--   this table yet as of this migration.
-- ⚠️ created_at uses SQLite's `datetime('now')`, which produces SPACE-
--   format timestamps ("YYYY-MM-DD HH:MM:SS"), matching sibling hook-
--   written table dispatch_decisions.created_at — NOT the ISO-T/Z form
--   agent_runs uses (produced in Python via
--   datetime.now(timezone.utc).isoformat()). cast.db timestamp formats are
--   genuinely mixed across tables; comparing a space-format column against
--   an ISO-T/Z string with raw `<`/`>` under- or over-matches depending on
--   direction. Any future query joining ack_events.created_at against an
--   ISO-T/Z column must normalize first — do not assume a blanket format
--   across the DB.
-- No defensive parent-table CREATE is needed (this is CREATE TABLE, not
--   ALTER TABLE ADD COLUMN like migration 033) — a bare CREATE TABLE IF NOT
--   EXISTS is idempotent against both a fresh DB and a DB where
--   cast-db-init.sh already provisioned the identical table, which is the
--   normal case since cast-db-init.sh is the SINGLE SOURCE OF TRUTH for
--   fresh installs and carries the same CREATE TABLE block (migrations do
--   not run at install; this migration backfills existing/legacy DBs).
-- No foreign key on session_id: agent_runs deliberately stores NULL over
--   '' specifically to avoid FK orphans when a session row is pruned or was
--   never written (headless/cron invocations); ack_events follows the same
--   reasoning for the same column.

CREATE TABLE IF NOT EXISTS ack_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  variable    TEXT NOT NULL,
  value       TEXT,
  has_reason  INTEGER NOT NULL DEFAULT 0,
  script      TEXT,
  git_sha     TEXT,
  session_id  TEXT,
  repo        TEXT,
  created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_ack_events_variable ON ack_events(variable);
CREATE INDEX IF NOT EXISTS idx_ack_events_created_at ON ack_events(created_at);
