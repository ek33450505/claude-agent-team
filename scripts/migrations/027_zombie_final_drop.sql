-- Migration 027: final zombie-column drop (post-026 re-seed remediation)
-- 026 applied 2026-07-02T16:17:10Z but the then-running pre-v2.6.0 dashboard
-- auto-seed re-added the columns after apply; preconditions re-verified 2026-07-03
-- (dashboard v2.6.0 zero-write startup shipped 2026-07-02; cast-desktop
-- canonical-strict; no flagship writer references).
-- cast-migrate.py tolerates 'no such column' so this is idempotent/fresh-DB-safe.
-- SQLite 3.35+ ALTER TABLE DROP COLUMN.

-- idx_agent_runs_project must be dropped first if present (SQLite blocks DROP
-- COLUMN with a live index); verified absent on live today, guard kept anyway.
DROP INDEX IF EXISTS idx_agent_runs_project;
ALTER TABLE agent_runs DROP COLUMN project;
ALTER TABLE agent_runs DROP COLUMN prompt;
ALTER TABLE sessions DROP COLUMN total_input_tokens;
ALTER TABLE sessions DROP COLUMN total_output_tokens;
ALTER TABLE sessions DROP COLUMN total_cost_usd;
ALTER TABLE sessions DROP COLUMN model;
