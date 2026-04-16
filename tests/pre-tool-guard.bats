#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/pre-tool-guard.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/agent-status"
  mkdir -p "$CLAUDE_DIR/cast/hook-last-fired"

  # Unset guard bypass env vars
  unset CLAUDE_SUBPROCESS
  unset CAST_POLICY_OVERRIDE
  unset CAST_COMMIT_AGENT
  unset CAST_PUSH_OK
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CLAUDE_DIR
}

# Helper: create a JSON status file with a specific mtime
create_status_file() {
  local name="$1"
  local age_minutes="$2"  # age in minutes from now
  local content="$3"

  local fpath="$CLAUDE_DIR/agent-status/$name"
  echo "$content" > "$fpath"

  # Adjust mtime: -mmin +N means older than N minutes
  # We need to set the file to be exactly age_minutes old
  local target_epoch
  target_epoch=$(date -v-${age_minutes}M +%s 2>/dev/null || date -d "-${age_minutes} minutes" +%s 2>/dev/null)
  touch -t "$(date -r "$target_epoch" +%Y%m%d%H%M.%S 2>/dev/null || echo '202301011200.00')" "$fpath" 2>/dev/null || touch -d "@${target_epoch}" "$fpath" 2>/dev/null || true
}

# Helper: create a Bash tool input JSON
make_bash_payload() {
  local cmd="${1:-echo test}"
  python3 -c "
import json
print(json.dumps({
  'tool_name': 'Bash',
  'tool_input': {
    'command': '$cmd',
    'description': 'test command'
  }
}))
" 2>/dev/null || echo '{"tool_name":"Bash","tool_input":{"command":"'"$cmd"'"}}'
}

# Helper: create a Write tool input JSON
make_write_payload() {
  local file_path="${1:-/tmp/test.txt}"
  python3 -c "
import json
print(json.dumps({
  'tool_name': 'Write',
  'tool_input': {
    'file_path': '$file_path',
    'content': 'test content'
  }
}))
" 2>/dev/null || echo '{"tool_name":"Write","tool_input":{"file_path":"'"$file_path"'"}}'
}

# ---------------------------------------------------------------------------
# TTL Sweep Tests
# ---------------------------------------------------------------------------

@test "TTL sweep: file older than 120 minutes is deleted" {
  # Create a file that is 150 minutes old (should be deleted)
  create_status_file "agent-old.json" 150 '{"status":"DONE"}'

  # Verify it exists before the hook
  [[ -f "$CLAUDE_DIR/agent-status/agent-old.json" ]]

  # Run hook with a Write tool call (triggers policy check and TTL sweep)
  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # File should be deleted by the sweep
  [[ ! -f "$CLAUDE_DIR/agent-status/agent-old.json" ]]
}

@test "TTL sweep: fresh file (less than 120 min old) is preserved" {
  # Create a file that is 60 minutes old (should be kept)
  create_status_file "agent-fresh.json" 60 '{"status":"DONE_WITH_CONCERNS"}'

  [[ -f "$CLAUDE_DIR/agent-status/agent-fresh.json" ]]

  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # File should still exist
  [[ -f "$CLAUDE_DIR/agent-status/agent-fresh.json" ]]
}

@test "TTL sweep: file 119 minutes old is preserved (below deletion threshold)" {
  # Create a file that is 119 minutes old (unambiguously below the 120 min deletion threshold)
  create_status_file "agent-boundary.json" 119 '{"status":"DONE"}'

  [[ -f "$CLAUDE_DIR/agent-status/agent-boundary.json" ]]

  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # File should still exist (below the +120 deletion threshold)
  [[ -f "$CLAUDE_DIR/agent-status/agent-boundary.json" ]]
}

@test "TTL sweep: multiple old files are all deleted" {
  create_status_file "agent1.json" 150 '{"status":"DONE"}'
  create_status_file "agent2.json" 200 '{"status":"DONE"}'
  create_status_file "agent3.json" 60 '{"status":"DONE"}'  # Should keep this one

  [[ -f "$CLAUDE_DIR/agent-status/agent1.json" ]]
  [[ -f "$CLAUDE_DIR/agent-status/agent2.json" ]]
  [[ -f "$CLAUDE_DIR/agent-status/agent3.json" ]]

  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # Old files deleted, fresh file kept
  [[ ! -f "$CLAUDE_DIR/agent-status/agent1.json" ]]
  [[ ! -f "$CLAUDE_DIR/agent-status/agent2.json" ]]
  [[ -f "$CLAUDE_DIR/agent-status/agent3.json" ]]
}

# ---------------------------------------------------------------------------
# Blocking Logic Tests
# ---------------------------------------------------------------------------

@test "Bash tool with safe echo command → passes guard (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "echo hello")"
  assert_success
}

@test "Bash tool with safe ls command → passes guard (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "ls -la /tmp")"
  assert_success
}

@test "git commit without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m 'test'")"
  assert_failure
  assert_output --partial "git commit"
}

@test "git push without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git push origin main")"
  assert_failure
  assert_output --partial "git push"
}

@test "git commit with CAST_COMMIT_AGENT escape hatch → allows (exit 0)" {
  # The escape hatch is in the command itself, which the script checks
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  assert_success
}

@test "git push with CAST_PUSH_OK escape hatch → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git push origin main")"
  assert_success
}

# ---------------------------------------------------------------------------
# Subprocess Guard Tests
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 → Bash tool with git commit allowed (subprocess bypass)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m 'test'")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 → Bash tool with git push allowed (subprocess bypass)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git push origin main")"
  assert_success
}

# ---------------------------------------------------------------------------
# Write/Edit Tool Policy Tests
# ---------------------------------------------------------------------------

@test "Write tool with safe path → passes (no policy blocking)" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"
  assert_success
}

@test "Write tool with safe path, subprocess=1 → passes" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"
  assert_success
}

# ---------------------------------------------------------------------------
# Hook Health Marker
# ---------------------------------------------------------------------------

@test "hook creates PreToolUse timestamp marker" {
  bash "$HOOK_SH" <<< "$(make_bash_payload "echo test")" >/dev/null 2>&1 || true

  [[ -f "$CLAUDE_DIR/cast/hook-last-fired/PreToolUse.timestamp" ]]
}

# ---------------------------------------------------------------------------
# Non-Bash Tools Pass Through
# ---------------------------------------------------------------------------

@test "Read tool input → passes through (not intercepted)" {
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
  'tool_name': 'Read',
  'tool_input': {
    'file_path': '/tmp/test.txt'
  }
}))
" 2>/dev/null)

  run bash "$HOOK_SH" <<< "$payload"
  assert_success
}

@test "Glob tool input → passes through (not intercepted)" {
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
  'tool_name': 'Glob',
  'tool_input': {
    'pattern': '*.txt'
  }
}))
" 2>/dev/null)

  run bash "$HOOK_SH" <<< "$payload"
  assert_success
}

# ---------------------------------------------------------------------------
# Git Command Variations and Edge Cases
# ---------------------------------------------------------------------------

@test "git commit as part of subcommand (git commit -m with quotes) → blocks without escape hatch" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m 'testing edge case'")"
  # Should block because no escape hatch
  assert_failure
}

@test "escape hatch leading cd chain → allows (tolerates leading cd)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "cd /tmp && CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  assert_success
}

# ---------------------------------------------------------------------------
# Empty Input Handling
# ---------------------------------------------------------------------------

@test "empty input → exits 0 (graceful no-op)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

@test "malformed JSON input → exits 0 (graceful failure)" {
  run bash "$HOOK_SH" <<< "not valid json at all"
  assert_success
}
