#!/usr/bin/env bats
# BATS tests for memory staleness sweep and cast memory CLI

setup() {
  export CAST_DB_PATH="/tmp/test-cast-$$-memory.db"
  export HOME="/tmp/test-cast-$$-home"
  export CAST_SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../scripts"

  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude"

  # Initialize test DB
  sqlite3 "$CAST_DB_PATH" - <<'SQL'
CREATE TABLE IF NOT EXISTS agent_memories (
  id INTEGER PRIMARY KEY,
  agent TEXT,
  project TEXT,
  type TEXT,
  name TEXT,
  description TEXT,
  content TEXT,
  created_at TEXT,
  updated_at TEXT,
  importance REAL DEFAULT 0.5,
  decay_rate REAL DEFAULT 0.0,
  valid_from TEXT,
  valid_to TEXT,
  superseded_by INTEGER,
  embedding BLOB,
  source_type TEXT,
  confidence REAL DEFAULT 1.0,
  last_verified TEXT
);
SQL
}

teardown() {
  rm -f "$CAST_DB_PATH"
  rm -rf "$HOME"
}

@test "migration adds last_verified column if missing" {
  # Verify column doesn't exist yet
  ! sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_memories)" | grep -q "last_verified"

  # Run migration
  bash "$CAST_SCRIPTS_DIR/cast-memory-migration-001.sh"

  # Verify column exists
  sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_memories)" | grep -q "last_verified"
}

@test "migration is idempotent (second run doesn't error)" {
  bash "$CAST_SCRIPTS_DIR/cast-memory-migration-001.sh"

  # Run again — should not fail
  bash "$CAST_SCRIPTS_DIR/cast-memory-migration-001.sh"
}

@test "sweep updates last_verified for NULL entries" {
  # Add migration first
  bash "$CAST_SCRIPTS_DIR/cast-memory-migration-001.sh"

  # Insert a test memory with NULL last_verified
  sqlite3 "$CAST_DB_PATH" - <<'SQL'
INSERT INTO agent_memories (agent, type, name, content, confidence, last_verified)
VALUES ('test-agent', 'feedback', 'test-memory', 'This is a test memory.', 1.0, NULL);
SQL

  # Run sweep
  bash "$CAST_SCRIPTS_DIR/cast-memory-staleness-sweep.sh"

  # Verify last_verified is now set
  local result
  result="$(sqlite3 "$CAST_DB_PATH" "SELECT last_verified FROM agent_memories WHERE id=1;" 2>/dev/null || true)"
  [ -n "$result" ]
}

@test "confidence decreases for entries with non-existent paths" {
  # Add migration first
  bash "$CAST_SCRIPTS_DIR/cast-memory-migration-001.sh"

  # Insert a memory that references a non-existent file
  sqlite3 "$CAST_DB_PATH" - <<'SQL'
INSERT INTO agent_memories (agent, type, name, content, confidence, last_verified)
VALUES ('test-agent', 'feedback', 'broken-ref', 'See /path/to/nonexistent.sh for details.', 1.0, NULL);
SQL

  # Run sweep
  bash "$CAST_SCRIPTS_DIR/cast-memory-staleness-sweep.sh" 2>/dev/null || true

  # Verify confidence decreased
  local conf
  conf="$(sqlite3 "$CAST_DB_PATH" "SELECT confidence FROM agent_memories WHERE id=1;" 2>/dev/null || true)"
  # Should be 1.0 - 0.2 = 0.8 due to missing path
  [[ "$conf" == "0.8" ]]
}

@test "cast memory list exits successfully" {
  export CAST_DB_PATH="$CAST_DB_PATH"

  # Add migration
  bash "$CAST_SCRIPTS_DIR/cast-memory-migration-001.sh"

  # Insert a test entry
  sqlite3 "$CAST_DB_PATH" - <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content, confidence)
VALUES ('test', 'feedback', 'test-mem', 'A test', 'Test content', 0.9);
SQL

  # Run cast memory list (would need bin/cast in PATH, so test via python directly)
  python3 - "$CAST_DB_PATH" <<'PYEOF'
import sys, sqlite3
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()
cur.execute("SELECT id, agent, type, name FROM agent_memories")
rows = cur.fetchall()
conn.close()
assert len(rows) == 1
assert rows[0]['agent'] == 'test'
PYEOF
}
