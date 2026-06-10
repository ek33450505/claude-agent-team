#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-start-hook.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_valid_payload() {
  local agent_name="${1:-test-agent}"
  local session_id="${2:-sess-abc123}"
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type': sys.argv[1],
    'session_id': sys.argv[2],
    'agent_id': 'agent-' + sys.argv[2][:8],
    'batch_id': '1',
}))
" "$agent_name" "$session_id"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/logs"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  unset CLAUDE_SUBPROCESS
  # Initialize an empty database
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY,
  agent TEXT,
  session_id TEXT,
  status TEXT,
  started_at TEXT,
  agent_id TEXT,
  batch_id INTEGER
);
SQL
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Test 1: Happy path — valid JSON produces event file and DB row
# ---------------------------------------------------------------------------

@test "valid subagent-start JSON → creates event file in cast/events/" {
  run bash "$HOOK_SH" <<< "$(make_valid_payload)"
  assert_success
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" | wc -l)
  [[ "$count" -ge 1 ]]
}

@test "valid subagent-start JSON → creates event file with correct type" {
  bash "$HOOK_SH" <<< "$(make_valid_payload)"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" | head -1)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('event_type') == 'task_claimed', f'event_type={d.get(\"event_type\")}'
assert d.get('agent'), f'missing agent field'
assert d.get('session_id'), f'missing session_id field'
print('ok')
" "$event_file"
}

@test "valid subagent-start JSON → inserts row into agent_runs table" {
  bash "$HOOK_SH" <<< "$(make_valid_payload "my-agent" "sess-xyz789")"
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE agent='my-agent' AND session_id='sess-xyz789';" | tr -d ' ')
  [[ "$count" -eq 1 ]]
}

@test "valid subagent-start JSON → agent_runs row has status=running" {
  bash "$HOOK_SH" <<< "$(make_valid_payload)"
  local status
  status=$(sqlite3 "$CAST_DB_PATH" "SELECT status FROM agent_runs LIMIT 1;" | tr -d ' ')
  [[ "$status" == "running" ]]
}

# ---------------------------------------------------------------------------
# Test 2: Empty stdin — graceful exit
# ---------------------------------------------------------------------------

@test "empty stdin → exits 0 (no-op)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

@test "empty stdin → creates no event files" {
  bash "$HOOK_SH" <<< ""
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" 2>/dev/null | wc -l)
  [[ "$count" -eq 0 ]]
}

@test "empty stdin → creates no DB rows" {
  bash "$HOOK_SH" <<< ""
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs;" | tr -d ' ')
  [[ "$count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Test 3: Error handling — malformed JSON handled gracefully
# ---------------------------------------------------------------------------

@test "malformed JSON → exits 0 (no crash)" {
  run bash "$HOOK_SH" <<< '{"incomplete": json'
  assert_success
}

# ---------------------------------------------------------------------------
# Test 5: JSON missing fields — still creates event/row with defaults
# ---------------------------------------------------------------------------

@test "JSON missing agent_name → uses 'unknown' fallback" {
  run bash "$HOOK_SH" <<< '{"session_id": "sess-123"}'
  assert_success
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*unknown*subagent-start.json" 2>/dev/null | head -1)
  [[ -n "$event_file" ]]
}

@test "JSON missing session_id → still creates event" {
  run bash "$HOOK_SH" <<< '{"agent_type": "test-agent"}'
  assert_success
}

# ---------------------------------------------------------------------------
# Test 6: Multiple consecutive calls — each creates independent event/row
# ---------------------------------------------------------------------------

@test "two consecutive calls → creates two event files" {
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent1" "sess1")"
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent2" "sess2")"
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" | wc -l)
  [[ "$count" -ge 2 ]]
}

@test "two consecutive calls → creates two DB rows" {
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent1" "sess1")"
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent2" "sess2")"
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs;" | tr -d ' ')
  [[ "$count" -eq 2 ]]
}

# ---------------------------------------------------------------------------
# Test 7: Unset session_id → DB row gets NULL not empty-string (FK-orphan fix)
# Phase 5 Wave 2: writers must emit NULL when CAST_SESSION_ID is unresolved.
# ---------------------------------------------------------------------------

@test "JSON missing session_id → agent_runs.session_id is NULL not empty-string" {
  bash "$HOOK_SH" <<< '{"agent_type": "no-sess-agent"}'
  local val
  val=$(sqlite3 "$CAST_DB_PATH" "SELECT COALESCE(session_id, 'IS_NULL') FROM agent_runs WHERE agent='no-sess-agent' LIMIT 1;")
  [[ "$val" == "IS_NULL" ]]
}
