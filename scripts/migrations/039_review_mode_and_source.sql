-- Migration 039: add review_snapshot_files.mode and review_gate_decisions.source
-- (CAST v10.6.2, content-bound review gate).
-- The gate bound approval to (path, blob) only. A blob is the same for a 100644 and a 100755
--   file, so an APPROVE of a non-executable file would also cover the same bytes staged as
--   executable (or as a symlink target). review_snapshot_files.mode records the git file mode
--   (100644 / 100755 / 120000) at snapshot time so the gate can require the staged index mode to
--   match the reviewed one. NULL for DELETED rows and for rows written before this migration;
--   a NULL mode never approves a non-deletion.
-- review_gate_decisions.source records who wrote the decision row: 'guard' (the PreToolUse git
--   guard calling the gate in-process) or 'cli' (cast-review-gate.py run at commit time). NULL =
--   written before this migration.
-- Mirrors the columns added to cast-db-init.sh (SINGLE SOURCE OF TRUTH for fresh DBs, plus a
--   self-heal ALTER); this migration backfills existing/legacy DBs. Bare ALTERs are safe --
--   cast-migrate.py tolerates both "no such table" and "duplicate column".
-- Additive and non-destructive: no existing row is read, rewritten or deleted.

ALTER TABLE review_snapshot_files ADD COLUMN mode TEXT;
ALTER TABLE review_gate_decisions ADD COLUMN source TEXT;
