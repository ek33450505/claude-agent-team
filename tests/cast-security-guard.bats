#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-security-guard.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_payload() {
  local tool_name="$1"
  local file_path="${2:-}"
  local command="${3:-}"
  python3 -c "
import json, sys
tool = sys.argv[1]
fp = sys.argv[2]
cmd = sys.argv[3]
inp = {}
if fp: inp['file_path'] = fp
if cmd: inp['command'] = cmd
print(json.dumps({'tool_name': tool, 'tool_input': inp}))
" "$tool_name" "$file_path" "$command"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/hook-last-fired"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Match on .env file write
# ---------------------------------------------------------------------------

@test "Write .env file → stdout contains CAST-REVIEW-SECURITY" {
  run bash "$HOOK_SH" <<< "$(make_payload "Write" "/home/user/project/.env" "")"
  assert_success
  assert_output --partial "CAST-REVIEW-SECURITY"
}

# ---------------------------------------------------------------------------
# 2. Match on middleware/auth.ts edit
# ---------------------------------------------------------------------------

@test "Edit src/middleware/auth.ts → stdout contains CAST-REVIEW-SECURITY" {
  run bash "$HOOK_SH" <<< "$(make_payload "Edit" "src/middleware/auth.ts" "")"
  assert_success
  assert_output --partial "CAST-REVIEW-SECURITY"
}

# ---------------------------------------------------------------------------
# 3. Match on credentials.json write
# ---------------------------------------------------------------------------

@test "Write /app/credentials.json → stdout contains CAST-REVIEW-SECURITY" {
  run bash "$HOOK_SH" <<< "$(make_payload "Write" "/app/credentials.json" "")"
  assert_success
  assert_output --partial "CAST-REVIEW-SECURITY"
}

# ---------------------------------------------------------------------------
# 4. Match on curl -u bash command
# ---------------------------------------------------------------------------

@test "Bash curl -u command → stdout contains CAST-REVIEW-SECURITY" {
  run bash "$HOOK_SH" <<< "$(make_payload "Bash" "" "curl -u admin:pass https://api.example.com/data")"
  assert_success
  assert_output --partial "CAST-REVIEW-SECURITY"
}

# ---------------------------------------------------------------------------
# 5. No match on ordinary source file
# ---------------------------------------------------------------------------

@test "Write src/components/Button.tsx → stdout is empty (no advisory)" {
  run bash "$HOOK_SH" <<< "$(make_payload "Write" "src/components/Button.tsx" "")"
  assert_success
  refute_output --partial "CAST-REVIEW-SECURITY"
}

# ---------------------------------------------------------------------------
# 6. No match on test file (skip guard)
# ---------------------------------------------------------------------------

@test "Write src/middleware/auth.test.ts → stdout is empty (test file skip)" {
  run bash "$HOOK_SH" <<< "$(make_payload "Write" "src/middleware/auth.test.ts" "")"
  assert_success
  refute_output --partial "CAST-REVIEW-SECURITY"
}

# ---------------------------------------------------------------------------
# 7. No match on non-Write/Edit/Bash tool
# ---------------------------------------------------------------------------

@test "Read tool with .env file_path → stdout is empty (tool not matched)" {
  run bash "$HOOK_SH" <<< "$(make_payload "Read" ".env" "")"
  assert_success
  refute_output --partial "CAST-REVIEW-SECURITY"
}

# ---------------------------------------------------------------------------
# 8. Exit code is always 0 (advisory only, never blocks)
# ---------------------------------------------------------------------------

@test "Matching .env payload → exit code is 0" {
  run bash "$HOOK_SH" <<< "$(make_payload "Write" "/home/user/project/.env" "")"
  assert_equal "$status" 0
}

# ---------------------------------------------------------------------------
# 9. hookSpecificOutput JSON is valid and has required keys
# ---------------------------------------------------------------------------

@test "Matching .env payload → stdout is valid JSON with hookSpecificOutput.additionalContext" {
  run bash "$HOOK_SH" <<< "$(make_payload "Write" "/home/user/project/.env" "")"
  assert_success
  # Verify the output is valid JSON with the expected key
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'hookSpecificOutput' in d, 'missing hookSpecificOutput key'
assert 'additionalContext' in d['hookSpecificOutput'], 'missing additionalContext key'
print('valid')
"
}
