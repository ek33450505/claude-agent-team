#!/usr/bin/env bats
# test_agent_response_capture.bats
# Tests for agent response capture (migration 011):
#   - hook writes response column when payload has agent_response.content
#   - hook writes response from flat last_assistant_message fallback
#   - hook leaves response NULL when no agent output in payload
#   - hook handles alternate payload field names (output, body)
#   - agent_truncations row written when response lacks Status block (regression)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"

_make_db() {
  local db="$1"
  sqlite3 "$db" "
    CREATE TABLE agent_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent TEXT,
      session_id TEXT,
      agent_id TEXT,
      status TEXT,
      started_at TEXT,
      ended_at TEXT,
      duration_ms INTEGER,
      tool_uses INTEGER,
      response TEXT
    );
    CREATE TABLE agent_truncations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT,
      agent_type TEXT NOT NULL,
      agent_id TEXT,
      batch_id INTEGER,
      last_line TEXT,
      timestamp TEXT NOT NULL,
      char_count INTEGER,
      has_status INTEGER DEFAULT 0,
      has_json INTEGER DEFAULT 0,
      partial_work_log TEXT
    );
  "
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/cast/truncated-agents"
  mkdir -p "$HOME/.claude/logs"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  _make_db "$CAST_DB_PATH"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ── Test 1: structured agent_response.content path ───────────────────────────

@test "response column written from agent_response.content (structured path)" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('code-writer','sess1','aid1','running','2026-01-01T00:00:00Z');"

  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'code-writer',
    'session_id': 'sess1',
    'agent_id': 'aid1',
    'stop_reason': 'end_turn',
    'agent_response': {
        'content': [
            {'type': 'text', 'text': 'I implemented the feature.'},
            {'type': 'text', 'text': '\n\nStatus: DONE\nSummary: Feature implemented.'},
        ]
    }
}))
")

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local result
  result=$(sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='aid1';")
  [[ "$result" == *"I implemented the feature"* ]]
  [[ "$result" == *"Status: DONE"* ]]
}

# ── Test 2: flat last_assistant_message fallback ──────────────────────────────

@test "response column written from last_assistant_message fallback" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('commit','sess2','aid2','running','2026-01-01T00:00:00Z');"

  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'commit',
    'session_id': 'sess2',
    'agent_id': 'aid2',
    'stop_reason': 'end_turn',
    'last_assistant_message': 'Committed changes.\n\nStatus: DONE\nSummary: Commit created.',
}))
")

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local result
  result=$(sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='aid2';")
  [[ "$result" == *"Committed changes"* ]]
}

# ── Test 3: response is NULL when no agent output in payload ──────────────────

@test "response stays NULL when payload has no agent output" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('commit','sess3','aid3','running','2026-01-01T00:00:00Z');"

  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'commit',
    'session_id': 'sess3',
    'agent_id': 'aid3',
    'stop_reason': 'end_turn',
}))
")

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local result
  result=$(sqlite3 "$CAST_DB_PATH" "SELECT response IS NULL FROM agent_runs WHERE agent_id='aid3';")
  [ "$result" = "1" ]
}

# ── Test 4: alternate payload field names (output, body) ──────────────────────

@test "response column written from 'output' field (alternate payload key)" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('planner','sess4','aid4','running','2026-01-01T00:00:00Z');"

  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'planner',
    'session_id': 'sess4',
    'agent_id': 'aid4',
    'stop_reason': 'end_turn',
    'output': 'Plan created with 5 tasks.\n\nStatus: DONE\nSummary: Plan written.',
}))
")

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local result
  result=$(sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='aid4';")
  [[ "$result" == *"Plan created with 5 tasks"* ]]
}

# ── Test 5: agent_truncations written when response lacks Status block ─────────

@test "agent_truncations row written when response has no Status block (truncation regression)" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at) VALUES ('researcher','sess5','aid5','running','2026-01-01T00:00:00Z');"

  # Generate a 60+ char response with no Status block (simulates truncation)
  local truncated_output
  truncated_output=$(python3 -c "print('This is agent output line ' + str(i) + ' ' for i in range(10))")
  truncated_output="I was researching the topic when the connection was interrupted and I did not get to finish my"

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'agent_type': 'researcher',
    'session_id': 'sess5',
    'agent_id': 'aid5',
    'stop_reason': 'end_turn',
    'last_assistant_message': sys.argv[1],
}))
" "$truncated_output")

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_truncations WHERE agent_type='researcher' AND session_id='sess5';")
  [ "$count" = "1" ]
}
