CREATE TABLE IF NOT EXISTS routines (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  trigger_type TEXT NOT NULL,
  trigger_value TEXT,
  agent_to_dispatch TEXT NOT NULL,
  prompt_template TEXT NOT NULL,
  output_dir TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_run_at TEXT,
  last_run_status TEXT,
  last_run_output_path TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_routines_name ON routines(name);
CREATE INDEX IF NOT EXISTS idx_routines_trigger ON routines(trigger_type, enabled);
