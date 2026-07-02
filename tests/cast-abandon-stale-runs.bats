#!/usr/bin/env bats
# Tests for cast-abandon-stale-runs.py
# Covers: agent_runs abandoned step + new sessions crash-marking step (v7.5-phase6).
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-abandon-stale-runs.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/cast-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  # Provision schema via authoritative init script (provisions agent_runs + sessions)
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
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

# --- incident emission (LF-4: INCIDENT-BLIND fix) ---

@test "reaped stale run inserts one incidents row with correct surfaced_by and resolution_status" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('reaper-bot','running','$old_ts');"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  inc_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents WHERE surfaced_by='stale-run-reaper';")
  [ "$inc_count" -eq 1 ]
  res_status=$(sqlite3 "$TEST_DB" "SELECT resolution_status FROM incidents WHERE surfaced_by='stale-run-reaper';")
  [ "$res_status" = "open" ]
}

@test "no incidents row when nothing is stale" {
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('fresh-bot','running', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  run python3 "$SCRIPT"
  assert_success
  inc_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents WHERE surfaced_by='stale-run-reaper';")
  [ "$inc_count" -eq 0 ]
}

@test "reap still succeeds when incidents table is missing" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('bot-no-inc','running','$old_ts');"
  sqlite3 "$TEST_DB" "DROP TABLE IF EXISTS incidents;"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  # agent_runs row must still be flipped despite missing incidents table
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE status='abandoned';")
  [ "$count" -eq 1 ]
}
