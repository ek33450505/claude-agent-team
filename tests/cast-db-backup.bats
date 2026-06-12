#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_DB_BACKUP_PY="$REPO_DIR/scripts/cast-db-backup.py"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  export TEST_DB="$HOME/.claude/cast.db"
  export TEST_BACKUP_DIR="$HOME/.claude/backups"

  mkdir -p "$HOME/.claude"

  # Create a minimal test SQLite database
  python3 -c "
import sqlite3, os
db_path = os.environ['TEST_DB']
conn = sqlite3.connect(db_path)
conn.execute('CREATE TABLE test_data (id INTEGER PRIMARY KEY, value TEXT)')
conn.execute(\"INSERT INTO test_data VALUES (1, 'hello')\")
conn.commit()
conn.close()
"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "cast-db-backup.py: creates backup file" {
  run python3 "$CAST_DB_BACKUP_PY"
  assert_success

  # Parse JSON output
  BACKUP_PATH=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['backup_path'])")
  [ -f "$BACKUP_PATH" ]
}

@test "cast-db-backup.py: backup is a valid SQLite database" {
  run python3 "$CAST_DB_BACKUP_PY"
  assert_success

  BACKUP_PATH=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['backup_path'])")

  # Verify we can query the backup
  RESULT=$(python3 -c "
import sqlite3
conn = sqlite3.connect('$BACKUP_PATH')
val = conn.execute('SELECT value FROM test_data WHERE id=1').fetchone()[0]
print(val)
conn.close()
")
  [ "$RESULT" = "hello" ]
}

@test "cast-db-backup.py: outputs valid JSON with expected fields" {
  run python3 "$CAST_DB_BACKUP_PY"
  assert_success

  # Validate JSON structure
  python3 -c "
import sys, json
data = json.loads('''$output''')
assert 'backup_path' in data, 'missing backup_path'
assert 'size_bytes' in data, 'missing size_bytes'
assert 'retained' in data, 'missing retained'
assert 'pruned' in data, 'missing pruned'
assert data['size_bytes'] > 0, 'size should be > 0'
"
}

@test "cast-db-backup.py: retention prunes old backups" {
  # Create 10 fake old backups
  mkdir -p "$TEST_BACKUP_DIR"
  for i in $(seq 1 10); do
    DAY=$(printf "%02d" $i)
    touch "$TEST_BACKUP_DIR/cast-db-2025-01-${DAY}.db"
  done

  run python3 "$CAST_DB_BACKUP_PY"
  assert_success

  # Parse pruned count — should have pruned some
  PRUNED=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['pruned'])")
  [ "$PRUNED" -gt 0 ]
}

@test "cast-db-backup.py: error on missing source DB" {
  export CAST_DB_PATH="$HOME/.claude/nonexistent.db"
  run python3 "$CAST_DB_BACKUP_PY"
  assert_failure

  # Should have error in JSON
  python3 -c "
import sys, json
data = json.loads('''$output''')
assert 'error' in data, 'expected error field'
assert data['backup_path'] is None, 'backup_path should be None on error'
"
}

@test "cast-db-backup.py: same-day re-run is idempotent (one file, not two)" {
  # First run
  run python3 "$CAST_DB_BACKUP_PY"
  assert_success

  FIRST_PATH=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['backup_path'])")

  # Second run same day
  run python3 "$CAST_DB_BACKUP_PY"
  assert_success

  SECOND_PATH=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['backup_path'])")

  # Paths must be identical (same date → same filename)
  [ "$FIRST_PATH" = "$SECOND_PATH" ]

  # Only one backup file should exist for today
  TODAY=$(date +%Y-%m-%d)
  COUNT=$(ls "$TEST_BACKUP_DIR"/cast-db-${TODAY}.db 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" -eq 1 ]
}
