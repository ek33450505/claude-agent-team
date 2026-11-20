#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-model-switch-hook.sh"

setup() {
  setup_temp_home
  export CAST_DB_PATH="$HOME/test-cast.db"
}

teardown() {
  teardown_temp_home
}

seed_db() {
  python3 -I -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
conn.execute('''
  CREATE TABLE routing_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT, timestamp TEXT, prompt_preview TEXT, action TEXT,
    matched_route TEXT, pattern TEXT, confidence REAL, project TEXT,
    event_type TEXT, data TEXT
  )
''')
conn.commit()
conn.close()
"
}

count_rows() {
  python3 -I -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(conn.execute('SELECT COUNT(*) FROM routing_events').fetchone()[0])
"
}

query_one() {
  python3 -I -c "
import sqlite3, os, sys
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(conn.execute(sys.argv[1]).fetchone()[0])
" "$1"
}

full_payload() {
  printf '%s' '{"session_id":"sess-1","cwd":"/tmp/some-project","hook_event_name":"PostModelSwitch","from_model":"claude-opus-5-5","to_model":"claude-sonnet-5-5","requested_model":null,"source":"command","context_tokens":1234,"prompt_cache_warm":true,"cache_ttl":"5m","estimated_cache_write_usd":0.02,"pricing":"catalog"}'
}

@test "full payload inserts exactly one model_switch row" {
  seed_db
  run bash -c "printf '%s' '$(full_payload)' | bash '$HOOK_SH'"
  assert_success
  [ "$(count_rows)" = "1" ]
  [ "$(query_one "SELECT event_type FROM routing_events")" = "model_switch" ]
  [ "$(query_one "SELECT matched_route FROM routing_events")" = "claude-sonnet-5-5" ]
  [ "$(query_one "SELECT action FROM routing_events")" = "command" ]
  [ "$(query_one "SELECT project FROM routing_events")" = "some-project" ]
  [ "$(query_one "SELECT json_extract(data, '\$.from_model') FROM routing_events")" = "claude-opus-5-5" ]
  [ "$(query_one "SELECT json_extract(data, '\$.to_model') FROM routing_events")" = "claude-sonnet-5-5" ]
}

@test "hook prints nothing to stdout" {
  seed_db
  run bash -c "printf '%s' '$(full_payload)' | bash '$HOOK_SH' 2>/dev/null"
  assert_success
  assert_output ""
}

@test "payload without to_model inserts no row" {
  seed_db
  run bash -c "printf '%s' '{\"session_id\":\"s\",\"from_model\":\"a\"}' | bash '$HOOK_SH'"
  assert_success
  [ "$(count_rows)" = "0" ]
}

@test "invalid JSON inserts no row and exits 0" {
  seed_db
  run bash -c "printf '%s' 'not json {' | bash '$HOOK_SH'"
  assert_success
  [ "$(count_rows)" = "0" ]
}

@test "missing DB exits 0 and does not create the DB" {
  [ ! -e "$CAST_DB_PATH" ]
  run bash -c "printf '%s' '$(full_payload)' | bash '$HOOK_SH'"
  assert_success
  [ ! -e "$CAST_DB_PATH" ]
}

@test "CLAUDE_SUBPROCESS=1 exits 0 without writing" {
  seed_db
  run bash -c "printf '%s' '$(full_payload)' | CLAUDE_SUBPROCESS=1 bash '$HOOK_SH'"
  assert_success
  [ "$(count_rows)" = "0" ]
}

@test "non-dict JSON inserts no row and exits 0" {
  seed_db
  run bash -c "printf '%s' '[]' | bash '$HOOK_SH'"
  assert_success
  run bash -c "printf '%s' '\"str\"' | bash '$HOOK_SH'"
  assert_success
  [ "$(count_rows)" = "0" ]
}

@test "dict-valued session_id and int-valued source still insert one row" {
  seed_db
  run bash -c "printf '%s' '{\"session_id\":{\"a\":1},\"source\":7,\"to_model\":\"m\"}' | bash '$HOOK_SH' 2>/dev/null"
  assert_success
  assert_output ""
  [ "$(count_rows)" = "1" ]
}

@test "50k-char to_model is capped to 200 in matched_route" {
  seed_db
  python3 -I -c "
import json
print(json.dumps({'session_id': 's', 'to_model': 'x' * 50000}))
" > "$HOME/big.json"
  run bash -c "bash '$HOOK_SH' < '$HOME/big.json'"
  assert_success
  [ "$(query_one "SELECT length(matched_route) FROM routing_events")" = "200" ]
}

@test "list-valued pricing keeps the data column within 4000 chars" {
  seed_db
  python3 -I -c "
import json
print(json.dumps({'session_id': 's', 'to_model': 'm', 'pricing': ['abcdef'] * 10000}))
" > "$HOME/big.json"
  run bash -c "bash '$HOOK_SH' < '$HOME/big.json'"
  assert_success
  [ "$(count_rows)" = "1" ]
  [ "$(query_one "SELECT length(data) FROM routing_events")" -le 4000 ]
  [ "$(query_one "SELECT json_valid(data) FROM routing_events")" = "1" ]
  [ "$(query_one "SELECT json_extract(data, '\$.truncated') FROM routing_events")" = "1" ]
}

@test "DB without a routing_events table exits 0 silently and leaves it untouched" {
  python3 -I -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
conn.execute('CREATE TABLE other (id INTEGER)')
conn.commit()
conn.close()
"
  run bash -c "printf '%s' '$(full_payload)' | bash '$HOOK_SH' 2>/dev/null"
  assert_success
  assert_output ""
  [ ! -e "$HOME/.claude/logs/hook-errors.log" ] || ! grep -q "model_switch" "$HOME/.claude/logs/hook-errors.log"
  [ "$(query_one "SELECT count(*) FROM sqlite_master WHERE name='routing_events'")" = "0" ]
}

@test "INSERT failure exits 0 silently and logs to hook-errors.log" {
  python3 -I -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
conn.execute('CREATE TABLE routing_events (id INTEGER PRIMARY KEY, session_id TEXT)')
conn.commit()
conn.close()
"
  run bash -c "printf '%s' '$(full_payload)' | bash '$HOOK_SH' 2>/dev/null"
  assert_success
  assert_output ""
  run grep -c "model_switch row not recorded" "$HOME/.claude/logs/hook-errors.log"
  assert_success
}
