#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  export TEST_TMPDIR="$(mktemp -d /tmp/cast-stop-test.XXXXXXXX)"
  export TEMP_DB="$TEST_TMPDIR/test.db"
  sqlite3 "$TEMP_DB" "CREATE TABLE agent_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT,
    session_id TEXT,
    agent_id TEXT,
    status TEXT,
    started_at TEXT,
    ended_at TEXT,
    duration_ms INTEGER,
    tool_uses INTEGER,
    response TEXT,
    cache_read_input_tokens INTEGER,
    cache_creation_input_tokens INTEGER,
    cost_usd REAL,
    input_tokens INTEGER,
    output_tokens INTEGER,
    model TEXT
  );"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
  teardown_temp_home
}

@test "SubagentStop: computes duration_ms from timestamps and counts tool_uses" {
  sqlite3 "$TEMP_DB" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('test-agent','s1','aid1','running','2026-01-01T00:00:00Z');"
  # Payload carries no duration_ms: production SubagentStop payloads don't; the hook
  # computes duration from started_at->ended_at. tool_uses is still counted from the array.
  local payload='{"agent_type":"test-agent","session_id":"s1","agent_id":"aid1","stop_reason":"end_turn","tool_uses":[{},{}]}'
  run bash -c "echo '$payload' | CAST_DB_PATH='$TEMP_DB' bash '$HOOK_SH'"
  assert_success
  local duration tool_uses
  duration=$(sqlite3 "$TEMP_DB" "SELECT duration_ms FROM agent_runs WHERE agent_id='aid1';")
  tool_uses=$(sqlite3 "$TEMP_DB" "SELECT tool_uses FROM agent_runs WHERE agent_id='aid1';")
  [ "$tool_uses" = "2" ]
  [ -n "$duration" ] && [ "$duration" -gt 0 ]
}

@test "SubagentStop: missing payload duration_ms still computes duration from timestamps (not NULL)" {
  sqlite3 "$TEMP_DB" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('test-agent','s2','aid2','running','2026-01-01T00:00:00Z');"
  local payload='{"agent_type":"test-agent","session_id":"s2","agent_id":"aid2","stop_reason":"end_turn"}'
  run bash -c "echo '$payload' | CAST_DB_PATH='$TEMP_DB' bash '$HOOK_SH'"
  assert_success
  local duration tool_uses
  duration=$(sqlite3 "$TEMP_DB" "SELECT duration_ms FROM agent_runs WHERE agent_id='aid2';")
  tool_uses=$(sqlite3 "$TEMP_DB" "SELECT tool_uses FROM agent_runs WHERE agent_id='aid2';")
  [ "$tool_uses" = "0" ]
  [ -n "$duration" ] && [ "$duration" -gt 0 ]
}

@test "SubagentStop: empty stdin exits 0 without error" {
  run bash -c "echo '' | CAST_DB_PATH='$TEMP_DB' bash '$HOOK_SH'"
  assert_success
}

@test "SubagentStop: tool_uses array length is counted correctly" {
  sqlite3 "$TEMP_DB" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('test-agent','s3','aid3','running','2026-01-01T00:00:00Z');"
  local payload='{"agent_type":"test-agent","session_id":"s3","agent_id":"aid3","stop_reason":"end_turn","duration_ms":100,"tool_uses":[1,2,3,4,5]}'
  run bash -c "echo '$payload' | CAST_DB_PATH='$TEMP_DB' bash '$HOOK_SH'"
  assert_success
  local result
  result=$(sqlite3 "$TEMP_DB" "SELECT tool_uses FROM agent_runs WHERE agent_id='aid3';")
  [ "$result" = "5" ]
}
