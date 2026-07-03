-- Migration 028: retire dead columns and unstaged_warnings table (2026-07-03 producer audit)
-- Decision recorded by Ed 2026-07-03 after confirming zero live population:
--   dispatch_decisions: effort, wave_id, parallel — never populated (25/468 rows populated, none use these cols)
--   task_queue: claimed_at, completed_at, scheduled_for — consumer removed in v9 I9; write-only queue
--   agent_truncations: has_status, has_json — hardcoded 0,0 at every write site; batch_id — never written
--   agent_protocol_violations: batch_id — INSERT at cast-subagent-stop-hook.sh:1118-1123 never includes it
--   agent_runs: owns_files — no writer ever found; 0/6146 rows populated
--   unstaged_warnings — 0 rows ever; part5_unstaged_warning deleted from cast-post-tool.py
-- SQLite 3.35+ required (ALTER TABLE DROP COLUMN). CAST runtime: SQLite 3.51.
-- cast-migrate.py tolerates 'no such column'/'no such table' on DROP, so safe on fresh DBs and re-runs.

-- Drop unstaged_warnings indexes before dropping the table (SQLite requirement)
DROP INDEX IF EXISTS idx_uw_session;
DROP INDEX IF EXISTS idx_uw_timestamp;
DROP TABLE IF EXISTS unstaged_warnings;

-- dispatch_decisions: retire three never-populated routing-telemetry columns
ALTER TABLE dispatch_decisions DROP COLUMN effort;
ALTER TABLE dispatch_decisions DROP COLUMN wave_id;
ALTER TABLE dispatch_decisions DROP COLUMN parallel;

-- task_queue: retire lifecycle columns whose consumer was removed in v9 I9
ALTER TABLE task_queue DROP COLUMN claimed_at;
ALTER TABLE task_queue DROP COLUMN completed_at;
ALTER TABLE task_queue DROP COLUMN scheduled_for;

-- agent_truncations: retire hardcoded-zero columns and never-written batch_id
ALTER TABLE agent_truncations DROP COLUMN has_status;
ALTER TABLE agent_truncations DROP COLUMN has_json;
ALTER TABLE agent_truncations DROP COLUMN batch_id;

-- agent_protocol_violations: retire batch_id (never written by any INSERT path)
ALTER TABLE agent_protocol_violations DROP COLUMN batch_id;

-- agent_runs: retire owns_files (no writer; 0/6146 rows ever populated)
ALTER TABLE agent_runs DROP COLUMN owns_files;
