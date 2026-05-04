-- Migration 011: Agent response capture
-- Adds response TEXT column to agent_runs so downstream consumers
-- (dashboard work-log feed) can read what each agent produced.
-- Applied by: cast-subagent-stop-hook.sh (idempotent ALTER on each run)
--
-- The column is TEXT (not BLOB) because agent responses are UTF-8 text.
-- Populated going forward only — historical rows remain NULL.

ALTER TABLE agent_runs ADD COLUMN response TEXT;
