-- Migration 015: Retire stream_hook_events (stub table, 0 rows, no writer)
DROP TABLE IF EXISTS stream_hook_events;
DROP INDEX IF EXISTS idx_stream_hook_events_session;
