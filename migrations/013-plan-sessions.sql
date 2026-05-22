-- 013-plan-sessions.sql
-- Links an orchestrate session to the plan file it is executing.
CREATE TABLE IF NOT EXISTS plan_sessions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    plan_file  TEXT NOT NULL,
    started_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_plan_sessions_session ON plan_sessions(session_id);
