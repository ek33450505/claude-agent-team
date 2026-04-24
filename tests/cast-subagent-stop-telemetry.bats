#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

HOOK_SH="$HOME/.claude/scripts/cast-subagent-stop-hook.sh"

setup() {
  export ORIG_HOME="$HOME"
  export TEMP_DB="$(mktemp /tmp/cast-test-XXXX.db)"
  sqlite3 "$TEMP_DB" "CREATE TABLE agent_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT,
    session_id TEXT,
    agent_id TEXT,
    status TEXT,
    started_at TEXT,
    ended_at TEXT,
    duration_ms INTEGER,
    tool_uses INTEGER
  );"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  [ -n "${TEMP_DB:-}" ] && rm -f "$TEMP_DB"
}

@test "SubagentStop: writes duration_ms and tool_uses to agent_runs" {
  sqlite3 "$TEMP_DB" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('test-agent','s1','aid1','running','2026-01-01T00:00:00Z');"
  local payload='{"agent_type":"test-agent","session_id":"s1","agent_id":"aid1","stop_reason":"end_turn","duration_ms":4200,"tool_uses":[{},{}]}'
  run bash -c "echo '$payload' | CAST_DB_PATH='$TEMP_DB' bash '$HOOK_SH'"
  assert_success
  local result
  result=$(sqlite3 "$TEMP_DB" "SELECT duration_ms, tool_uses FROM agent_runs WHERE agent_id='aid1';")
  [ "$result" = "4200|2" ]
}

@test "SubagentStop: missing duration_ms writes 0 (not NULL)" {
  sqlite3 "$TEMP_DB" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('test-agent','s2','aid2','running','2026-01-01T00:00:00Z');"
  local payload='{"agent_type":"test-agent","session_id":"s2","agent_id":"aid2","stop_reason":"end_turn"}'
  run bash -c "echo '$payload' | CAST_DB_PATH='$TEMP_DB' bash '$HOOK_SH'"
  assert_success
  local result
  result=$(sqlite3 "$TEMP_DB" "SELECT duration_ms, tool_uses FROM agent_runs WHERE agent_id='aid2';")
  [ "$result" = "0|0" ]
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
