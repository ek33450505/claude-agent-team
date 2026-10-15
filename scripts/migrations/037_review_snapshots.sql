-- Migration 037: add review_snapshots + review_snapshot_files (CAST v10.6.0, U1a).
-- Finding: nothing enforces "reviewed before commit" -- the approval gate matches any
--   same-session reviewer agent_runs row with status DONE, and agent_runs.status is run
--   status, never the reviewer's verdict. The content-bound review gate
--   (plans/design/2026-10-15-content-bound-review-gate.md) instead records WHICH BLOBS
--   (path + git blob sha) were present, unchanged, during a reviewer run, and what the
--   run decided. This migration provisions the storage half only:
--   scripts/cast_review_snapshot.py record() is the single writer, called by the
--   SubagentStop hook; read by scripts/cast-review-gate.py.
-- review_snapshots: one row per reviewer run. decision is the combined result of the
--   parsed Verdict line AND the passing Status gate (APPROVE or BLOCKED only).
-- scope: 'files' = the BLOCK/APPROVE covers only the child rows; 'repo' = degraded BLOCK
--   written when the snapshot or record failed (no child rows) -- it blocks the whole
--   repo_root so a BLOCK verdict is never lost to a snapshot failure.
-- review_snapshot_files: one row per covered path (APPROVE: unchanged start->stop;
--   BLOCKED: every path either snapshot saw) (blob = 40-hex git sha, or 'DELETED'). ON DELETE CASCADE keeps the
--   child rows in step with the parent; the FK is enforced only when the writer connection
--   sets PRAGMA foreign_keys=ON (record() does).
-- ⚠️ created_at uses SQLite's `datetime('now')` (SPACE format "YYYY-MM-DD HH:MM:SS"),
--   like ack_events.created_at -- NOT the ISO-T/Z form agent_runs uses. started_at /
--   ended_at are caller-supplied strings (ISO-T/Z from the hook). Do not raw-compare
--   across the two formats; normalise first.
-- No foreign key on session_id/agent_id (agent_runs stores NULL over '' to avoid FK
--   orphans when a session row is pruned or was never written).
-- Bare CREATE TABLE IF NOT EXISTS is idempotent against both a fresh DB and one where
--   cast-db-init.sh (the single source of truth for fresh installs) already created the
--   identical tables; this migration backfills existing/legacy DBs.

CREATE TABLE IF NOT EXISTS review_snapshots (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT,
  agent_id    TEXT,
  reviewer    TEXT NOT NULL,
  repo_root   TEXT NOT NULL,
  decision    TEXT NOT NULL CHECK(decision IN ('APPROVE','BLOCKED')),
  scope       TEXT NOT NULL DEFAULT 'files' CHECK(scope IN ('files','repo')),
  started_at  TEXT,
  ended_at    TEXT,
  created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_review_snapshots_repo_root ON review_snapshots(repo_root);
CREATE INDEX IF NOT EXISTS idx_review_snapshots_created_at ON review_snapshots(created_at);

CREATE TABLE IF NOT EXISTS review_snapshot_files (
  snapshot_id INTEGER NOT NULL REFERENCES review_snapshots(id) ON DELETE CASCADE,
  path        TEXT NOT NULL,
  blob        TEXT NOT NULL,
  PRIMARY KEY (snapshot_id, path)
);
CREATE INDEX IF NOT EXISTS idx_review_snapshot_files_path_blob ON review_snapshot_files(path, blob);
