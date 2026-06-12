#!/usr/bin/env bats
# Tests for cast-lint-write-only-tables.py
#
# Gate contract: ADVISORY — always exits 0 unless --strict is passed.
# Hermetic: uses temp dirs + env overrides; never touches live ~/.claude or
# the real repo's cast-db-init.sh during fixture tests.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_PY="$REPO_DIR/scripts/cast-lint-write-only-tables.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp HOME + fixture workspace per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  FAKE_ROOT="$(mktemp -d)"
  mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/agents" "$FAKE_ROOT/bin" "$FAKE_ROOT/skills"
}

teardown() {
  [[ "$FAKE_ROOT" == "$HOME"* || "$FAKE_ROOT" == /tmp/* || "$FAKE_ROOT" == /var/folders/* ]] \
    || { echo "refusing to rm outside tmp: $FAKE_ROOT" >&2; return 1; }
  rm -rf "$FAKE_ROOT"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_db_init() {
  # Usage: _write_db_init "table1 table2 ..."
  local init_file="$FAKE_ROOT/scripts/cast-db-init.sh"
  printf '#!/bin/bash\n' > "$init_file"
  for tbl in $1; do
    printf 'CREATE TABLE IF NOT EXISTS %s (id TEXT);\n' "$tbl" >> "$init_file"
  done
}

_write_reader() {
  # Write a script that reads from a table
  # Usage: _write_reader "table_name" "filename.py"
  local tbl="$1"
  local fname="${2:-reader.py}"
  printf 'SELECT id FROM %s WHERE 1;\n' "$tbl" > "$FAKE_ROOT/scripts/$fname"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "exit 0 when db-init not found (advisory — never crash)" {
  # No db-init file at all — should warn and exit 0
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/nonexistent.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
}

@test "exit 0 when all tables have read evidence" {
  _write_db_init "events sessions"
  _write_reader "events" "read-events.py"
  _write_reader "sessions" "read-sessions.py"
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
  refute_output --partial "WARN"
}

@test "exit 0 and prints WARN for unread table (advisory mode)" {
  _write_db_init "events orphan_table"
  _write_reader "events" "read-events.py"
  # orphan_table has no reader
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
  assert_output --partial "WARN [lint-write-only-tables]: orphan_table"
}

@test "WARN line includes canonical message format" {
  _write_db_init "ghost_table"
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
  assert_output --partial "ghost_table — created but never read in this repo"
}

@test "--strict exits 1 when there are warnings" {
  _write_db_init "unread_table"
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY" --strict
  assert_failure
  assert_output --partial "WARN [lint-write-only-tables]: unread_table"
}

@test "--strict exits 0 when all tables are read" {
  _write_db_init "users"
  _write_reader "users" "read-users.sh"
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY" --strict
  assert_success
  refute_output --partial "WARN"
}

@test "schema_migrations is excluded (allowlisted)" {
  _write_db_init "schema_migrations"
  # No reader for schema_migrations — should still exit 0 with no WARN
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
  refute_output --partial "schema_migrations"
}

@test "sqlite_master existence checks do NOT count as reads" {
  _write_db_init "swarm_sessions"
  # Write a script that only checks sqlite_master, not swarm_sessions data
  cat > "$FAKE_ROOT/scripts/check.py" <<'EOF'
cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='swarm_sessions'")
EOF
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
  assert_output --partial "WARN [lint-write-only-tables]: swarm_sessions"
}

@test "read in agents/ directory counts as evidence" {
  _write_db_init "quality_gates"
  printf 'SELECT * FROM quality_gates WHERE agent_name=?;\n' \
    > "$FAKE_ROOT/agents/some-agent.md"
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
  refute_output --partial "WARN"
}

@test "summary count line is printed when warnings exist" {
  _write_db_init "a_table b_table"
  # No readers
  run env CAST_DB_INIT_PATH="$FAKE_ROOT/scripts/cast-db-init.sh" \
         CAST_REPO_ROOT="$FAKE_ROOT" \
      python3 "$LINT_PY"
  assert_success
  assert_output --partial "2 write-only table(s)"
}
