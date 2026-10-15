-- Migration 038: add review_gate_decisions (CAST v10.6.0, U2).
-- Finding: the content-bound review gate (plans/design/2026-10-15-content-bound-review-gate.md)
--   ships first in WARN mode: scripts/cast-review-gate.py classifies every staged path as
--   approved/unreviewed/blocked/derived/hatched against review_snapshots (migration 037) and
--   never blocks. This table records ONE row per gate run so the would-block rate and its
--   false positives can be measured before enforcement is switched on.
-- would_block = 1 iff any path was unreviewed or blocked (after the CAST_UNREVIEWED_OK hatch).
-- reasons = JSON list of {path, category, reason} for non-approved paths only (<=50 entries,
--   <=16 KB). commit_sha is NULL here; a later unit fills it.
-- ⚠️ created_at uses SQLite datetime('now') (SPACE format), like review_snapshots.created_at.
-- Bare CREATE ... IF NOT EXISTS is idempotent against a fresh DB where cast-db-init.sh already
--   created the identical table; this migration backfills existing/legacy DBs.

CREATE TABLE IF NOT EXISTS review_gate_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  repo_root TEXT NOT NULL,
  mode TEXT NOT NULL DEFAULT 'warn' CHECK(mode IN ('warn','enforce')),
  would_block INTEGER NOT NULL CHECK(would_block IN (0,1)),
  n_staged INTEGER NOT NULL DEFAULT 0,
  n_approved INTEGER NOT NULL DEFAULT 0,
  n_unreviewed INTEGER NOT NULL DEFAULT 0,
  n_blocked INTEGER NOT NULL DEFAULT 0,
  n_derived INTEGER NOT NULL DEFAULT 0,
  n_hatched INTEGER NOT NULL DEFAULT 0,
  reasons TEXT,
  commit_sha TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_review_gate_decisions_repo ON review_gate_decisions(repo_root);
CREATE INDEX IF NOT EXISTS idx_review_gate_decisions_created ON review_gate_decisions(created_at);
