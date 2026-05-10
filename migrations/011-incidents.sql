CREATE TABLE IF NOT EXISTS incidents (
  id TEXT PRIMARY KEY,
  occurred_at TEXT NOT NULL,
  problem_summary TEXT NOT NULL,
  fix_summary TEXT,
  related_files TEXT,
  related_commit TEXT,
  resolution_status TEXT,
  surfaced_by TEXT
);

CREATE INDEX IF NOT EXISTS idx_incidents_occurred ON incidents(occurred_at);
