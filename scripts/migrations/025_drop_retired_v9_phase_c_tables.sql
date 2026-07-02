-- Migration 025: Drop v9 Phase C retired tables (M1-A consolidation)
-- stream_events, teammate_messages (retired U7a), code_ref_checks (retired U7b):
--   removed from canonical schema in v9 Phase C; verified 0 rows in live DB on
--   2026-07-02; no active writers (only the retired live-only cast-swarm-* scripts
--   reference them; the #294 team-logging hooks write teammate_runs, NOT
--   teammate_messages). DROP TABLE also drops any associated indexes.
DROP TABLE IF EXISTS stream_events;
DROP TABLE IF EXISTS teammate_messages;
DROP TABLE IF EXISTS code_ref_checks;
