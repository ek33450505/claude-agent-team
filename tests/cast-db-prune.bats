#!/usr/bin/env bats
# Tests for cast-db-prune.py
# Covers: correct column prune, dry-run mode, exit-0 guarantee, missing DB.
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-db-prune.py"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/cast-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Create minimal schema: routing_events(timestamp) + agent_runs(started_at)
  sqlite3 "$TEST_DB" "
    CREATE TABLE routing_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT
    );
    CREATE TABLE agent_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent TEXT,
      started_at TEXT
    );
  "
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# --- exit-0 guarantee ---

@test "exits 0 when DB does not exist" {
  export CAST_DB_PATH="/nonexistent/path/no-cast.db"
  run python3 "$SCRIPT"
  assert_success
}

@test "exits 0 on normal run with empty tables" {
  run python3 "$SCRIPT"
  assert_success
}

# --- routing_events prune (correct column: timestamp) ---

@test "deletes old routing_events row and keeps recent one" {
  # Old row: 200 days ago (well beyond 90-day default)
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-1 days'));
  "
  run python3 "$SCRIPT"
  assert_success
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  [ "$remaining" -eq 1 ]
  # The remaining row should be the recent one
  old_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events WHERE timestamp < datetime('now', '-90 days');")
  [ "$old_count" -eq 0 ]
}

# --- agent_runs prune (column: started_at) ---

@test "deletes old agent_runs row and keeps recent one" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-1 days'));
  "
  run python3 "$SCRIPT"
  assert_success
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$remaining" -eq 1 ]
  old_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE started_at < datetime('now', '-90 days');")
  [ "$old_count" -eq 0 ]
}

# --- dry-run mode ---

@test "dry-run preserves old rows but reports would-delete count" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  export CAST_DB_PRUNE_DRY_RUN=1
  run python3 "$SCRIPT"
  assert_success

  # Rows must still exist after dry-run
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]

  # Output must mention "would delete" counts
  assert_output --partial "would delete"
}

@test "dry-run reports 0 for tables with no old rows" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-1 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-1 days'));
  "
  export CAST_DB_PRUNE_DRY_RUN=1
  run python3 "$SCRIPT"
  assert_success
  assert_output --partial "would delete 0 row(s)"
}

# --- tolerance: missing table or column should not abort other step ---

@test "exits 0 even if routing_events table is missing" {
  sqlite3 "$TEST_DB" "DROP TABLE routing_events;"
  run python3 "$SCRIPT"
  assert_success
}

@test "exits 0 even if agent_runs table is missing" {
  sqlite3 "$TEST_DB" "DROP TABLE agent_runs;"
  run python3 "$SCRIPT"
  assert_success
}

# --- configurable retention ---

@test "respects CAST_DB_PRUNE_DAYS override" {
  # Insert a row 10 days old — within default 90-day window but outside 7-day window
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-10 days'));
  "
  export CAST_DB_PRUNE_DAYS=7
  run python3 "$SCRIPT"
  assert_success
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  [ "$remaining" -eq 0 ]
}
