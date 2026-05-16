-- Migration 014: drop unused model_used column from agent_runs.
-- Audit 2026-05-16 #3: column added v7 for Ollama contractor routing but no writer
-- was ever wired. Fill rate: 0/5234 rows. SQLite 3.35+ supports ALTER TABLE DROP COLUMN.
ALTER TABLE agent_runs DROP COLUMN model_used;
