-- Migration 024: Wave-3 Increment 3 — drop 3 coupled dead columns.
-- Evidence: agent_runs.task_summary 100% NULL (1583 rows), agent_runs.batch_id 100% NULL (1583 rows),
-- sessions.model 100% NULL (194 rows). cast-desktop reads removed in PR #80 (merged 8bcc9f5).
-- SQLite 3.35+ required (ALTER TABLE DROP COLUMN). CAST runtime: SQLite 3.51.
-- Migration ledger (schema_migrations) guarantees run-once (no guard needed here)
-- (mirrors precedent in 022_wave3_safe_column_drops.sql).

-- idx_agent_runs_batch_id must be dropped first (SQLite blocks DROP COLUMN with a live index)
DROP INDEX IF EXISTS idx_agent_runs_batch_id;

ALTER TABLE agent_runs DROP COLUMN task_summary;
ALTER TABLE agent_runs DROP COLUMN batch_id;
ALTER TABLE sessions DROP COLUMN model;
