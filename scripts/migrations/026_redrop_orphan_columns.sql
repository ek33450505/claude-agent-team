-- Migration 026: re-drop six orphan columns (M1-A2 consolidation)
-- Migrations 022/024 dropped these, but the then-canonical cast-db-init.sh
-- self-heal re-added them (they stayed canonical until v9 Phase C removed them).
-- Ledger says 022/024 applied, so a new migration must re-issue the DROPs.
-- Live data archived 2026-07-02 (1,518 agent_runs rows + 1 sessions row) to
-- ~/.claude/backups/orphan-columns-archive-2026-07-02.json before apply.
-- SQLite 3.35+ required (ALTER TABLE DROP COLUMN). CAST runtime: SQLite 3.51.
-- cast-migrate.py tolerates 'no such column' on DROP COLUMN, so this is safe on
-- fresh DBs (canonical schema never has these columns) and on re-runs.

-- idx_agent_runs_project must be dropped first if present (SQLite blocks DROP
-- COLUMN with a live index); verified absent on live today, guard kept anyway.
DROP INDEX IF EXISTS idx_agent_runs_project;
ALTER TABLE agent_runs DROP COLUMN project;
ALTER TABLE agent_runs DROP COLUMN prompt;
ALTER TABLE sessions DROP COLUMN total_input_tokens;
ALTER TABLE sessions DROP COLUMN total_output_tokens;
ALTER TABLE sessions DROP COLUMN total_cost_usd;
ALTER TABLE sessions DROP COLUMN model;
