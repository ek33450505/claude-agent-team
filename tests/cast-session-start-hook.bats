#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

HOOK_SH="/Users/edkubiak/.claude/scripts/cast-session-start-hook.sh"

make_payload() {
  local session_id="${1:-test-session-001}"
  local cwd="${2:-/tmp/test-project}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'SessionStart',
    'session_id': sys.argv[1],
    'cwd':        sys.argv[2],
}))
" "$session_id" "$cwd"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast"
  unset CLAUDE_SUBPROCESS
  unset CLAUDE_ENV_FILE
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Happy path: valid JSON → exits 0
# ---------------------------------------------------------------------------

@test "valid SessionStart payload → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 2. Happy path: log file created with correct fields
# ---------------------------------------------------------------------------

@test "valid payload → appends to session-starts.jsonl" {
  run bash "$HOOK_SH" <<< "$(make_payload "sess-abc" "/projects/foo")"
  assert_success
  [ -f "$HOME/.claude/cast/session-starts.jsonl" ]
  python3 -c "
import json
with open('$HOME/.claude/cast/session-starts.jsonl') as f:
    d = json.loads(f.readline().strip())
assert d.get('session_id') == 'sess-abc',       f'session_id={d.get(\"session_id\")}'
assert d.get('cwd')        == '/projects/foo',  f'cwd={d.get(\"cwd\")}'
assert 'timestamp' in d,                         'missing timestamp'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 3. CLAUDE_SUBPROCESS guard
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 → exits 0 and writes nothing" {
  CLAUDE_SUBPROCESS=1 run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
  [ ! -f "$HOME/.claude/cast/session-starts.jsonl" ]
}

# ---------------------------------------------------------------------------
# 4. Missing CLAUDE_ENV_FILE — still logs, skips env write
# ---------------------------------------------------------------------------

@test "no CLAUDE_ENV_FILE → still logs to session-starts.jsonl" {
  unset CLAUDE_ENV_FILE
  run bash "$HOOK_SH" <<< "$(make_payload "sess-noenv" "/tmp")"
  assert_success
  [ -f "$HOME/.claude/cast/session-starts.jsonl" ]
}

# ---------------------------------------------------------------------------
# 5. CLAUDE_ENV_FILE set → env vars written to it
# ---------------------------------------------------------------------------

@test "CLAUDE_ENV_FILE set → writes CAST_SESSION_ID, CAST_SESSION_CWD, CAST_SESSION_START_TS" {
  local env_file="$HOME/cast-env.sh"
  export CLAUDE_ENV_FILE="$env_file"
  bash "$HOOK_SH" <<< "$(make_payload "sess-envtest" "/home/user/project")"
  [ -f "$env_file" ]
  grep -q "CAST_SESSION_ID=sess-envtest"        "$env_file"
  grep -q "CAST_SESSION_CWD=/home/user/project" "$env_file"
  grep -q "CAST_SESSION_START_TS="              "$env_file"
}

# ---------------------------------------------------------------------------
# 6. Invalid JSON → exits 0 (never crash)
# ---------------------------------------------------------------------------

@test "invalid JSON input → exits 0 gracefully" {
  run bash "$HOOK_SH" <<< "not valid json {"
  assert_success
}

# ---------------------------------------------------------------------------
# 7. Empty input → exits 0
# ---------------------------------------------------------------------------

@test "empty input → exits 0" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

# ---------------------------------------------------------------------------
# 8. Multiple calls → appends, not overwrites
# ---------------------------------------------------------------------------

@test "two payloads → two lines in jsonl" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-1" "/tmp/a")"
  bash "$HOOK_SH" <<< "$(make_payload "sess-2" "/tmp/b")"
  local lines
  lines=$(wc -l < "$HOME/.claude/cast/session-starts.jsonl")
  [ "$lines" -eq 2 ]
}
