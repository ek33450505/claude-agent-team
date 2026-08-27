#!/usr/bin/env bats
# C1 (ship criterion): a dispatch whose message is lost in transport must surface
# its response WITHOUT a manual `cast review`.
#
# Every path that fed response_text read the PAYLOAD — agent_response.content, then
# last_assistant_message / output / body, then a terminal tool_use block. When the
# payload carries none of them the row stores nothing and stage 16 emits nothing,
# so the orchestrator sees silence. The reaper's recovery pass exists but only
# targets status IN ('failed','abandoned'), so a DONE run was never a candidate.
#
# Measured 2026-08-27 over 14 days: 264 DONE runs with an empty response, and all
# 264 had their transcript on disk (median 71 KB). The text was always there.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/scripts/cast_subagent_stop.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_HOOK_DIR="$REPO_DIR/scripts"
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  SID="sess-c1"
  SUBS="$HOME/.claude/projects/-probe/$SID/subagents"
  mkdir -p "$SUBS"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO sessions (id,project,project_root,started_at,status)
    VALUES ('$SID','probe','/probe','2026-08-27T18:00:00Z','active');"
}

teardown() { teardown_temp_home; }

# $1=agent_id, $2=transcript body (one JSON object per line)
_seed() {
  local aid="$1"; shift
  printf '%s\n' "$@" > "$SUBS/agent-${aid}.jsonl"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (session_id,agent,agent_id,started_at,status)
    VALUES ('$SID','code-reviewer','${aid}','2026-08-27T18:00:01Z','running');"
}

# Fire SubagentStop with an EMPTY message — the transport-loss shape.
_fire_empty() {
  CAST_STOP_INPUT="$(printf '{"session_id":"%s","agent_type":"code-reviewer","agent_id":"%s","cwd":"/probe","last_assistant_message":""}' "$SID" "$1")" \
    python3 "$HOOK" 2>/dev/null
}

@test "C1: an empty payload recovers the response from the transcript" {
  _seed c1a \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"first turn"}],"usage":{"input_tokens":10,"output_tokens":5}}}' \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"Status: DONE\nSummary: reviewed the diff"}],"usage":{"input_tokens":3,"output_tokens":2}}}'
  _fire_empty c1a >/dev/null
  run sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='c1a';"
  assert_output --partial "recovered-from-transcript"
  assert_output --partial "reviewed the diff"
}

@test "C1: the LAST assistant turn is recovered, not the first" {
  _seed c1b \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"early scratch note"}],"usage":{"input_tokens":1,"output_tokens":1}}}' \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"the actual verdict"}],"usage":{"input_tokens":1,"output_tokens":1}}}'
  _fire_empty c1b >/dev/null
  run sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='c1b';"
  assert_output --partial "the actual verdict"
  refute_output --partial "early scratch note"
}

@test "C1: a terminal StructuredOutput call is recovered when there is no text" {
  _seed c1c \
    '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"StructuredOutput","input":{"verdict":"APPROVE"}}],"usage":{"input_tokens":1,"output_tokens":1}}}'
  _fire_empty c1c >/dev/null
  run sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='c1c';"
  assert_output --partial "StructuredOutput"
  assert_output --partial "APPROVE"
}

@test "C1: a payload that DID carry text is never overwritten by the transcript" {
  _seed c1d \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"stale transcript text"}],"usage":{"input_tokens":1,"output_tokens":1}}}'
  CAST_STOP_INPUT="$(printf '{"session_id":"%s","agent_type":"code-reviewer","agent_id":"c1d","cwd":"/probe","last_assistant_message":"the real handed-back message"}' "$SID")" \
    python3 "$HOOK" >/dev/null 2>&1
  run sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='c1d';"
  assert_output "the real handed-back message"
  refute_output --partial "recovered-from-transcript"
}

@test "C1: a user turn is not mistaken for the agent's response" {
  _seed c1e \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"agent output here"}],"usage":{"input_tokens":1,"output_tokens":1}}}' \
    '{"message":{"role":"user","content":[{"type":"text","text":"PROMPT TEXT DO NOT RECOVER"}]}}'
  _fire_empty c1e >/dev/null
  run sqlite3 "$CAST_DB_PATH" "SELECT response FROM agent_runs WHERE agent_id='c1e';"
  assert_output --partial "agent output here"
  refute_output --partial "DO NOT RECOVER"
}

@test "C1: an empty payload with no transcript stays empty and does not break" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (session_id,agent,agent_id,started_at,status)
    VALUES ('$SID','docs','c1f','2026-08-27T18:00:01Z','running');"
  _fire_empty c1f >/dev/null
  run sqlite3 "$CAST_DB_PATH" "SELECT status || '|' || COALESCE(response,'NULL') FROM agent_runs WHERE agent_id='c1f';"
  assert_output "DONE|NULL"
}
