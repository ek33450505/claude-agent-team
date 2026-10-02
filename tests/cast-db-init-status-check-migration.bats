#!/usr/bin/env bats
# Audit B-3: a failed agent_runs status-CHECK migration must be loud + durable
# (stderr WARN + hook-errors.log line) but never fatal; `cast doctor` must flag a
# live legacy CHECK and must NOT false-positive on the DDL's "-- no CHECK" comment.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export TDB="$HOME/test-cast.db"
  export CAST_DB_PATH="$TDB"
  export CLAUDE_SUBPROCESS=0
  # Private copy of the scripts dir so a stub helper can replace the real one.
  export SCRIPTS_COPY="$HOME/scripts-copy"
  mkdir -p "$SCRIPTS_COPY"
  cp "$REPO_DIR"/scripts/* "$SCRIPTS_COPY"/ 2>/dev/null || true
}

teardown() {
  teardown_temp_home
}

@test "failing status-check helper: init exits 0, WARNs on stderr, logs to hook-errors.log" {
  printf 'import sys\nsys.exit(1)\n' >"$SCRIPTS_COPY/cast-db-drop-status-check.py"
  run bash "$SCRIPTS_COPY/cast-db-init.sh" --db "$TDB"
  assert_success
  assert_output --partial "status CHECK migration FAILED (rc=1)"
  run grep -c "status CHECK migration FAILED (rc=1)" "$HOME/.claude/logs/hook-errors.log"
  assert_success
  assert_output "1"
}

@test "succeeding status-check helper: no WARN and no log line" {
  run bash "$SCRIPTS_COPY/cast-db-init.sh" --db "$TDB"
  assert_success
  refute_output --partial "migration FAILED"
  [ ! -f "$HOME/.claude/logs/hook-errors.log" ] || ! grep -q "migration FAILED" "$HOME/.claude/logs/hook-errors.log"
}

@test "doctor WARNs when agent_runs carries a live status CHECK" {
  sqlite3 "$TDB" "CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, status TEXT, CHECK (status IN ('DONE','running')));"
  run bash "$REPO_DIR/bin/cast" doctor
  assert_output --partial "agent_runs status check: legacy CHECK still present"
}

@test "doctor is OK when DDL only has the '-- no CHECK' comment (false-positive regression)" {
  sqlite3 "$TDB" "CREATE TABLE agent_runs (
  id INTEGER PRIMARY KEY,
  -- no CHECK: agent_runs is observability; status is free-form
  status TEXT
);"
  run bash "$REPO_DIR/bin/cast" doctor
  assert_output --partial "agent_runs status check: none"
  refute_output --partial "legacy CHECK still present"
}
