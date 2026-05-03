-- Migration 009: CAST framework fixes tables
-- Applied by: cast migrate

CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT,
  agent_type   TEXT NOT NULL,
  agent_id     TEXT,
  batch_id     INTEGER,
  violation    TEXT NOT NULL,
  pattern      TEXT,
  timestamp    TEXT NOT NULL,
  raw_excerpt  TEXT
);

CREATE INDEX IF NOT EXISTS idx_apv_session ON agent_protocol_violations(session_id);
CREATE INDEX IF NOT EXISTS idx_apv_agent_type ON agent_protocol_violations(agent_type);
CREATE INDEX IF NOT EXISTS idx_apv_timestamp ON agent_protocol_violations(timestamp);

CREATE TABLE IF NOT EXISTS agent_truncations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT,
  agent_type   TEXT NOT NULL,
  agent_id     TEXT,
  batch_id     INTEGER,
  last_line    TEXT,
  timestamp    TEXT NOT NULL,
  char_count   INTEGER,
  has_status   INTEGER DEFAULT 0,
  has_json     INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_at_session ON agent_truncations(session_id);
CREATE INDEX IF NOT EXISTS idx_at_agent_type ON agent_truncations(agent_type);

CREATE TABLE IF NOT EXISTS unstaged_warnings (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  commit_sha      TEXT,
  unstaged_files  TEXT,
  in_scope_files  TEXT,
  timestamp       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_uw_session ON unstaged_warnings(session_id);
CREATE INDEX IF NOT EXISTS idx_uw_timestamp ON unstaged_warnings(timestamp);

-- Add owns_files to agent_runs (needed by B-1 unstaged warning hook)
ALTER TABLE agent_runs ADD COLUMN owns_files TEXT;

-- quality_gates already exists in cast.db (verified). Register as v7 baseline
-- so the migration system knows the table is tracked without recreating it.
CREATE TABLE IF NOT EXISTS quality_gates (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  batch_id INTEGER,
  agent_name TEXT,
  timestamp TEXT,
  status_line TEXT,
  contract_passed INTEGER,
  retry_count INTEGER
);
