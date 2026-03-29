#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-instructions-loaded-hook.sh"

make_payload() {
  local file_path="${1:-/Users/ed/.claude/CLAUDE.md}"
  local memory_type="${2:-User}"
  local load_reason="${3:-session_start}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'InstructionsLoaded',
    'file_path':   sys.argv[1],
    'memory_type': sys.argv[2],
    'load_reason': sys.argv[3],
    'session_id':  'test-session-789',
    'cwd':         '/tmp/project',
}))
" "$file_path" "$memory_type" "$load_reason"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Exit 0 on valid session_start payload
# ---------------------------------------------------------------------------

@test "session_start payload → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 2. Exit 0 on empty input
# ---------------------------------------------------------------------------

@test "empty input → exits 0 (graceful no-op)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

# ---------------------------------------------------------------------------
# 3. Writes to instructions-loaded.jsonl
# ---------------------------------------------------------------------------

@test "valid payload → appends to instructions-loaded.jsonl" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
  [ -f "$HOME/.claude/cast/instructions-loaded.jsonl" ]
  local lines
  lines=$(wc -l < "$HOME/.claude/cast/instructions-loaded.jsonl")
  [ "$lines" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 4. Log entry is valid JSON with correct fields
# ---------------------------------------------------------------------------

@test "log entry has file_path, memory_type, load_reason" {
  bash "$HOOK_SH" <<< "$(make_payload "/home/ed/.claude/CLAUDE.md" "User" "session_start")"
  python3 -c "
import json
with open('$HOME/.claude/cast/instructions-loaded.jsonl') as f:
    d = json.loads(f.readline().strip())
assert d.get('file_path')   == '/home/ed/.claude/CLAUDE.md', f'file_path={d.get(\"file_path\")}'
assert d.get('memory_type') == 'User',          f'memory_type={d.get(\"memory_type\")}'
assert d.get('load_reason') == 'session_start', f'load_reason={d.get(\"load_reason\")}'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 5. Multiple calls append, not overwrite
# ---------------------------------------------------------------------------

@test "two payloads → two lines in jsonl" {
  bash "$HOOK_SH" <<< "$(make_payload "/a/CLAUDE.md" "Project" "session_start")"
  bash "$HOOK_SH" <<< "$(make_payload "/b/CLAUDE.md" "Local"   "session_start")"
  local lines
  lines=$(wc -l < "$HOME/.claude/cast/instructions-loaded.jsonl")
  [ "$lines" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 6. CLAUDE_SUBPROCESS guard — skips silently
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 → exits 0 and writes nothing" {
  CLAUDE_SUBPROCESS=1 run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
  [ ! -f "$HOME/.claude/cast/instructions-loaded.jsonl" ]
}

# ---------------------------------------------------------------------------
# 7. session_id is recorded in the log entry
# ---------------------------------------------------------------------------

@test "log entry includes session_id from payload" {
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'hook_event_name': 'InstructionsLoaded',
    'file_path':   '/tmp/CLAUDE.md',
    'memory_type': 'Project',
    'load_reason': 'session_start',
    'session_id':  'unique-session-id-abc',
    'cwd':         '/tmp',
}))
")
  bash "$HOOK_SH" <<< "$payload"
  python3 -c "
import json
with open('$HOME/.claude/cast/instructions-loaded.jsonl') as f:
    d = json.loads(f.readline().strip())
assert d.get('session_id') == 'unique-session-id-abc', f'session_id={d.get(\"session_id\")}'
print('ok')
"
}
