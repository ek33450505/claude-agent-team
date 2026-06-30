#!/usr/bin/env bats
# Tests for cast-incident-record.sh
# Covers: incident insert on debugger+Status:DONE, no-op on wrong agent, no-op on missing status.
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-incident-record.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/cast-test-incident-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# Helper: count incidents rows
_count_incidents() {
  sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents;" 2>/dev/null || echo "0"
}

# Helper: write a JSON fixture to a temp file and return the path via stdout
_write_fixture() {
  local content="$1"
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$content" >"$tmp"
  echo "$tmp"
}

@test "debugger agent with Status: DONE inserts 1 incident row" {
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a1","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: fixed the thing\n## Handoff\nfiles_changed: [a.py]\nStatus: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]
}

@test "debugger incident row has expected surfaced_by and non-empty problem_summary" {
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a1","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: fixed the thing\n## Handoff\nfiles_changed: [a.py]\nStatus: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local surfaced_by
  surfaced_by="$(sqlite3 "$TEST_DB" "SELECT surfaced_by FROM incidents LIMIT 1;" 2>/dev/null)"
  [ "$surfaced_by" = "debugger" ]

  local summary
  summary="$(sqlite3 "$TEST_DB" "SELECT problem_summary FROM incidents LIMIT 1;" 2>/dev/null)"
  [ -n "$summary" ]
}

@test "non-debugger agent (code-writer) inserts 0 incident rows" {
  local payload
  payload='{"agent_type":"code-writer","session_id":"s1","agent_id":"a2","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: added feature\nStatus: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "debugger agent without Status: DONE inserts 0 incident rows" {
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a3","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: still investigating\n## Handoff\nfiles_changed: []\nStatus: BLOCKED"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "subprocess guard exits 0 immediately when CLAUDE_SUBPROCESS=1" {
  local payload
  payload='{"agent_type":"debugger","agent_response":{"content":[{"type":"text","text":"Status: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "empty stdin exits 0 and inserts 0 rows" {
  run bash "$SCRIPT" </dev/null
  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "redaction strips secret token from problem_summary before DB insert" {
  # Point HOOK_DIR at the repo scripts/ so cast-redact.py is reachable in the temp HOME
  export HOOK_DIR="$REPO_DIR/scripts"
  local fake_secret="sk-ant-api03-FAKE0000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  local fixture
  fixture="$(mktemp)"
  printf '{"agent_type":"debugger","session_id":"s-redact","agent_id":"a-redact","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: leaked %s and /Users/testuser/secret.txt\\n## Handoff\\nfiles_changed: []\\nStatus: DONE"}]}}' \
    "$fake_secret" >"$fixture"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local stored_summary
  stored_summary="$(sqlite3 "$TEST_DB" "SELECT problem_summary FROM incidents LIMIT 1;" 2>/dev/null)"
  # Redaction must have run — raw secret token must NOT appear in stored summary
  [[ "$stored_summary" != *"$fake_secret"* ]]
}
