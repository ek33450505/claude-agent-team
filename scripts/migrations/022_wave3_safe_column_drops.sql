-- Migration 022: Wave-3 Increment 1 — drop 11 verified-dead columns.
-- All columns verified 100% NULL in cast.db (pre-migration backup held by orchestrator).
-- Verified against cast-desktop server SQL layer: none of these columns are read.
-- SQLite 3.35+ required (ALTER TABLE DROP COLUMN). CAST runtime: SQLite 3.51.
-- Migration ledger (schema_migrations) guarantees run-once (no guard needed here)
-- (mirrors precedent in 014_drop_agent_runs_model_used.sql and 015).

-- routing_events: agent-attribution + match_type never wired to a writer
ALTER TABLE routing_events DROP COLUMN match_type;
ALTER TABLE routing_events DROP COLUMN agent_id;
ALTER TABLE routing_events DROP COLUMN agent_type;

-- agent_memories: superseded_by / source_type never populated
ALTER TABLE agent_memories DROP COLUMN superseded_by;
ALTER TABLE agent_memories DROP COLUMN source_type;

-- quality_gates: batch_id written nowhere (fill rate 0%)
ALTER TABLE quality_gates DROP COLUMN batch_id;

-- sessions: token/cost rollup columns — cost pipeline moved off these in Phase 5
ALTER TABLE sessions DROP COLUMN total_input_tokens;
ALTER TABLE sessions DROP COLUMN total_output_tokens;
ALTER TABLE sessions DROP COLUMN total_cost_usd;

-- agent_runs: project + prompt never read; project duplicates sessions.project
-- idx_agent_runs_project must be dropped first (SQLite blocks DROP COLUMN with live index)
DROP INDEX IF EXISTS idx_agent_runs_project;
ALTER TABLE agent_runs DROP COLUMN project;
ALTER TABLE agent_runs DROP COLUMN prompt;
