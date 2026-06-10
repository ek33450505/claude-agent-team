-- Migration 020: Replace empty-string session_id with NULL in agent_runs
-- Root cause: writers fell back to empty-string or 'unknown' when CAST_SESSION_ID was
-- unset, creating FK-orphan rows (38 rows found in Phase 5 Wave 2 audit).
-- NULL is FK-exempt. Empty-string is not a valid sessions.id value.
-- Safe to re-run: WHERE clause is a no-op when no empty rows remain.
UPDATE agent_runs SET session_id = NULL WHERE session_id = '';
