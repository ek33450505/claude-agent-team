#!/usr/bin/env bats
# Tests for cast-abandon-stale-runs.py
# Covers: agent_runs abandoned step + new sessions crash-marking step (v7.5-phase6).
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-abandon-stale-runs.py"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/cast-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  # Provision schema via authoritative init script (provisions agent_runs + sessions)
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# --- agent_runs (existing behaviour) ---

@test "exits 0 when DB does not exist" {
  export CAST_DB_PATH="/nonexistent/path/no-cast.db"
  run python3 "$SCRIPT"
  assert_success
}

@test "exits 0 and logs nothing when no stale running rows" {
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('bot','running', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  run python3 "$SCRIPT"
  assert_success
  # Fresh row should NOT be abandoned
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE status='abandoned';")
  [ "$count" -eq 0 ]
}

@test "abandons agent_run stuck in running beyond threshold" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('bot','running','$old_ts');"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE status='abandoned';")
  [ "$count" -eq 1 ]
}

# --- sessions crash-marking (new behaviour, v7.5-phase6) ---

@test "flips stale active session to crashed" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO sessions (id, status, started_at) VALUES ('sess-stale','active','$old_ts');"
  export CAST_SESSION_CRASH_HOURS=4
  run python3 "$SCRIPT"
  assert_success
  status=$(sqlite3 "$TEST_DB" "SELECT status FROM sessions WHERE id='sess-stale';")
  [ "$status" = "crashed" ]
}

@test "does not flip fresh active session" {
  # Session started just now — well within the 4h threshold
  sqlite3 "$TEST_DB" "INSERT INTO sessions (id, status, started_at) VALUES ('sess-fresh','active',strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  export CAST_SESSION_CRASH_HOURS=4
  run python3 "$SCRIPT"
  assert_success
  status=$(sqlite3 "$TEST_DB" "SELECT status FROM sessions WHERE id='sess-fresh';")
  [ "$status" = "active" ]
}

@test "does not flip already-ended session" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=6)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO sessions (id, status, started_at) VALUES ('sess-ended','ended','$old_ts');"
  export CAST_SESSION_CRASH_HOURS=4
  run python3 "$SCRIPT"
  assert_success
  status=$(sqlite3 "$TEST_DB" "SELECT status FROM sessions WHERE id='sess-ended';")
  [ "$status" = "ended" ]
}
