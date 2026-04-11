#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude"

  export TEST_DB="/tmp/test-cast-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Core: db-init runs without error
# ---------------------------------------------------------------------------

@test "cast-db-init: exits 0 on fresh DB" {
  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
}

# ---------------------------------------------------------------------------
# Schema: core tables created
# ---------------------------------------------------------------------------

@test "cast-db-init: creates core tables (sessions, agent_runs, routing_events)" {
  bash "$DB_INIT" --db "$TEST_DB"

  local tables
  tables=$(sqlite3 "$TEST_DB" ".tables")
  [[ "$tables" == *"sessions"* ]]
  [[ "$tables" == *"agent_runs"* ]]
  [[ "$tables" == *"routing_events"* ]]
}

# ---------------------------------------------------------------------------
# Schema: swarm tables created (v8)
# ---------------------------------------------------------------------------

@test "cast-db-init: creates swarm_sessions table" {
  bash "$DB_INIT" --db "$TEST_DB"

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='swarm_sessions';")
  [ "$count" -eq 1 ]
}

@test "cast-db-init: creates teammate_runs table" {
  bash "$DB_INIT" --db "$TEST_DB"

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='teammate_runs';")
  [ "$count" -eq 1 ]
}

@test "cast-db-init: creates teammate_messages table" {
  bash "$DB_INIT" --db "$TEST_DB"

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='teammate_messages';")
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Schema version: PRAGMA user_version >= 8
# ---------------------------------------------------------------------------

@test "cast-db-init: PRAGMA user_version >= 8" {
  bash "$DB_INIT" --db "$TEST_DB"

  local version
  version=$(sqlite3 "$TEST_DB" "PRAGMA user_version;")
  [ "$version" -ge 8 ]
}

# ---------------------------------------------------------------------------
# Idempotent: running twice does not error
# ---------------------------------------------------------------------------

@test "cast-db-init: idempotent — running twice exits 0" {
  bash "$DB_INIT" --db "$TEST_DB"
  run bash "$DB_INIT" --db "$TEST_DB"
  assert_success
}

# ---------------------------------------------------------------------------
# Schema: swarm_sessions columns present
# ---------------------------------------------------------------------------

@test "cast-db-init: swarm_sessions has required columns" {
  bash "$DB_INIT" --db "$TEST_DB"

  local info
  info=$(sqlite3 "$TEST_DB" "PRAGMA table_info(swarm_sessions);")
  [[ "$info" == *"team_name"* ]]
  [[ "$info" == *"status"* ]]
  [[ "$info" == *"started_at"* ]]
}

# ---------------------------------------------------------------------------
# Schema: teammate_runs columns present
# ---------------------------------------------------------------------------

@test "cast-db-init: teammate_runs has required columns" {
  bash "$DB_INIT" --db "$TEST_DB"

  local info
  info=$(sqlite3 "$TEST_DB" "PRAGMA table_info(teammate_runs);")
  [[ "$info" == *"swarm_id"* ]]
  [[ "$info" == *"agent_role"* ]]
  [[ "$info" == *"worktree"* ]]
}

# ---------------------------------------------------------------------------
# Schema: teammate_messages columns present
# ---------------------------------------------------------------------------

@test "cast-db-init: teammate_messages has required columns" {
  bash "$DB_INIT" --db "$TEST_DB"

  local info
  info=$(sqlite3 "$TEST_DB" "PRAGMA table_info(teammate_messages);")
  [[ "$info" == *"swarm_id"* ]]
  [[ "$info" == *"from_agent"* ]]
  [[ "$info" == *"message_type"* ]]
  [[ "$info" == *"payload"* ]]
}
