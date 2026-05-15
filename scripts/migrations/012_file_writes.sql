-- Migration 012: File writes tracking for IDE gutter annotations
-- Captures per-file agent writes so Cast Desktop can render
-- gutter annotations like "code-writer last touched this file at 14:32."
-- Applied by: cast migrate (python3 scripts/cast-migrate.py)
-- Idempotent: safe to run multiple times

CREATE TABLE IF NOT EXISTS file_writes (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT,
  agent_name  TEXT,
  run_id      INTEGER,
  file_path   TEXT NOT NULL,
  tool_name   TEXT NOT NULL,
  ts          TEXT NOT NULL DEFAULT (datetime('now')),
  line_range  TEXT
);

CREATE INDEX IF NOT EXISTS idx_file_writes_path        ON file_writes(file_path);
CREATE INDEX IF NOT EXISTS idx_file_writes_session_ts  ON file_writes(session_id, ts);
CREATE INDEX IF NOT EXISTS idx_file_writes_run         ON file_writes(run_id);
