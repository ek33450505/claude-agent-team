#!/usr/bin/env bats
# tests/hooks/test_cast_migrate.bats
# Covers: scripts/cast-migrate.py

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
MIGRATE="$REPO_DIR/scripts/cast-migrate.py"

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  TEST_DB="$BATS_TEST_TMPDIR/test-migrate.db"
  export CAST_DB_PATH="$TEST_DB"

  # Create agent_runs table so migration ALTER TABLE ADD COLUMN succeeds
  python3 - <<'PYEOF'
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT, session_id TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, agent_id TEXT, duration_ms INTEGER
)''')
con.commit(); con.close()
PYEOF
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

table_exists() {
  python3 -c "
import sqlite3, sys, os
db = os.environ['CAST_DB_PATH']
name = sys.argv[1]
con = sqlite3.connect(db)
row = con.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name=?\", (name,)).fetchone()
print('yes' if row else 'no')
con.close()
" "$1"
}

column_exists() {
  python3 -c "
import sqlite3, sys, os
db = os.environ['CAST_DB_PATH']
table, col = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cols = [r[1] for r in con.execute(f'PRAGMA table_info({table})').fetchall()]
print('yes' if col in cols else 'no')
con.close()
" "$1" "$2"
}

migration_applied() {
  python3 -c "
import sqlite3, sys, os
db = os.environ['CAST_DB_PATH']
name = sys.argv[1]
con = sqlite3.connect(db)
try:
    row = con.execute('SELECT 1 FROM schema_migrations WHERE migration_name=?', (name,)).fetchone()
    print('yes' if row else 'no')
except Exception:
    print('no')
con.close()
" "$1"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. First run on fresh DB → applies migration, schema_migrations gets a row
@test "migrate: first run on fresh DB applies 009 migration" {
  run python3 "$MIGRATE"
  assert_success
  assert_output --partial "[APPLIED]"
  [ "$(migration_applied '009_cast_framework_fixes.sql')" = "yes" ]
}

# 2. Second run → already-applied, idempotent
@test "migrate: second run skips already-applied migration (idempotent)" {
  python3 "$MIGRATE" >/dev/null 2>&1  # first run
  run python3 "$MIGRATE"              # second run
  assert_success
  assert_output --partial "[SKIPPED]"
  # Still exactly 1 row for this migration
  local count
  count=$(python3 -c "
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
print(con.execute(\"SELECT COUNT(*) FROM schema_migrations WHERE migration_name='009_cast_framework_fixes.sql'\").fetchone()[0])
con.close()
")
  [ "$count" -eq 1 ]
}

# 3. --dry-run → reports pending migrations without applying
@test "migrate: --dry-run reports pending migrations without applying" {
  run python3 "$MIGRATE" --dry-run
  assert_success
  assert_output --partial "[PENDING]"
  assert_output --partial "Dry run"
  # No row applied since we did not apply
  [ "$(migration_applied '009_cast_framework_fixes.sql')" = "no" ]
}

# 4. agent_protocol_violations table exists after apply
@test "migrate: agent_protocol_violations table exists after apply" {
  python3 "$MIGRATE" >/dev/null 2>&1
  [ "$(table_exists 'agent_protocol_violations')" = "yes" ]
}

# 4b. agent_truncations table exists after apply
@test "migrate: agent_truncations table exists after apply" {
  python3 "$MIGRATE" >/dev/null 2>&1
  [ "$(table_exists 'agent_truncations')" = "yes" ]
}

# 4c. unstaged_warnings table exists after apply
@test "migrate: unstaged_warnings table exists after apply" {
  python3 "$MIGRATE" >/dev/null 2>&1
  [ "$(table_exists 'unstaged_warnings')" = "yes" ]
}

# 5. agent_runs.owns_files column exists after apply
@test "migrate: agent_runs.owns_files column exists after apply" {
  python3 "$MIGRATE" >/dev/null 2>&1
  [ "$(column_exists 'agent_runs' 'owns_files')" = "yes" ]
}

# 6. Symlink guard: a symlink in migrations dir is NOT included in discovered migrations
@test "migrate: symlink in migrations dir is skipped (symlink guard)" {
  local tmp_migrations tmp_db driver
  tmp_migrations="$(mktemp -d)"
  tmp_db="$BATS_TEST_TMPDIR/symlink-test.db"
  driver="$BATS_TEST_TMPDIR/find_migrations_driver.py"

  # Copy a real migration so the tool finds at least one legitimate file
  cp "$REPO_DIR/scripts/migrations/009_cast_framework_fixes.sql" "$tmp_migrations/"

  # Create a symlink named as a valid migration — must be excluded by the guard
  ln -s /etc/hosts "$tmp_migrations/099_evil.sql"

  # Write a small driver that exercises _find_migrations directly
  cat > "$driver" << 'DRIVER_EOF'
import sys, importlib.util, pathlib
migrations_dir = pathlib.Path(sys.argv[1])
migrate_path   = sys.argv[2]
spec = importlib.util.spec_from_file_location("cast_migrate", migrate_path)
mod  = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for _num, name, _path in mod._find_migrations(migrations_dir):
    print(name)
DRIVER_EOF

  local output
  output="$(python3 "$driver" "$tmp_migrations" "$MIGRATE" 2>&1)"

  # 099_evil.sql must NOT appear — symlink guard filters it out
  [[ "$output" != *"099_evil.sql"* ]]

  # 009 legitimate migration must appear
  [[ "$output" == *"009_cast_framework_fixes.sql"* ]]

  rm -rf "$tmp_migrations"
}
