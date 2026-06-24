#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-incident-record.sh"
INCIDENTS_MIGRATION="$REPO_DIR/scripts/migrations/017_incidents.sql"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"

  export TEST_DB="$BATS_TEST_TMPDIR/test-incident-record-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  sqlite3 "$TEST_DB" < "$INCIDENTS_MIGRATION"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

incident_count() {
  sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents;"
}

make_payload() {
  local agent_type="$1"
  local last_message="$2"
  local prompt="${3:-Investigate the failing test}"

  python3 - "$agent_type" "$last_message" "$prompt" <<'PY'
import json
import sys

agent_type, last_message, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "agent_type": agent_type,
    "agent_id": "debugger-123",
    "last_message_text": last_message,
    "original_prompt": prompt,
}))
PY
}

@test "cast-incident-record: non-debugger agent inserts no row" {
  payload="$(make_payload "code-writer" $'Status: DONE\nfixed it')"

  CAST_INPUT="$payload" run bash "$SCRIPT" <<< "$payload"

  assert_success
  [ "$(incident_count)" -eq 0 ]
}

@test "cast-incident-record: debugger without done status inserts no row" {
  payload="$(make_payload "debugger" $'Status: BLOCKED\nneeds more data')"

  CAST_INPUT="$payload" run bash "$SCRIPT" <<< "$payload"

  assert_success
  [ "$(incident_count)" -eq 0 ]
}

@test "cast-incident-record: debugger done inserts one open debugger incident" {
  payload="$(make_payload "debugger" $'Status: DONE\nfiles_changed: [scripts/example.sh]\nFixed the issue')"

  CAST_INPUT="$payload" run bash "$SCRIPT" <<< "$payload"

  assert_success
  [ "$(incident_count)" -eq 1 ]

  row="$(sqlite3 "$TEST_DB" "SELECT surfaced_by || '|' || resolution_status || '|' || related_files FROM incidents LIMIT 1;")"
  [ "$row" = "debugger|open|[scripts/example.sh]" ]
}

@test "cast-incident-record: empty stdin exits 0 and inserts no row" {
  payload="$(make_payload "debugger" $'Status: DONE\nfixed it')"

  CAST_INPUT="$payload" run bash "$SCRIPT" <<< ""

  assert_success
  [ "$(incident_count)" -eq 0 ]
}

@test "cast-incident-record: single quote in prompt does not break insert" {
  payload="$(make_payload "debugger" $'Status: DONE\nfixed it' "Fix Bob's failing debugger flow")"

  CAST_INPUT="$payload" run bash "$SCRIPT" <<< "$payload"

  assert_success
  [ "$(incident_count)" -eq 1 ]

  summary="$(sqlite3 "$TEST_DB" "SELECT problem_summary FROM incidents LIMIT 1;")"
  [ "$summary" = "Fix Bob's failing debugger flow" ]
}
