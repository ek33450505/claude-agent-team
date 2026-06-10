-- Migration 021: Remove sessions rows with NULL or empty id
-- Root cause: cast-session-start-hook.sh INSERTed before the session_id was resolved,
-- producing rows with no usable primary key (4 rows found, Phase 5 Wave 2 audit).
-- The sessions writer is now guarded to skip INSERT when id is empty/None.
-- Safe to re-run: DELETE WHERE is a no-op when no such rows remain.
DELETE FROM sessions WHERE id IS NULL OR id = '';
