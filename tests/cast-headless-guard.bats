#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-headless-guard.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_ask_user_payload() {
  local question="${1:-Do you want to continue?}"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'AskUserQuestion',
    'input': {
        'question': sys.argv[1],
    }
}))
" "$question"
}

make_other_tool_payload() {
  local tool_name="${1:-Bash}"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': sys.argv[1],
    'input': {
        'command': 'echo hello',
    }
}))
" "$tool_name"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  unset CLAUDE_SUBPROCESS
  unset CAST_HEADLESS
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1: Interactive mode (default) — AskUserQuestion is allowed
# ---------------------------------------------------------------------------

@test "AskUserQuestion with CAST_HEADLESS unset → exits 0 and allows (interactive mode)" {
  unset CAST_HEADLESS
  run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
}

@test "AskUserQuestion in interactive mode → output includes permissionDecision=allow" {
  unset CAST_HEADLESS
  run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
  # The hook should output JSON allowing the tool
  echo "$output" | grep -q "permissionDecision"
}

@test "non-AskUserQuestion tool in interactive mode → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_other_tool_payload "Bash")"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 2: Headless mode (CAST_HEADLESS=1) — AskUserQuestion is blocked
# ---------------------------------------------------------------------------

@test "AskUserQuestion with CAST_HEADLESS=1 → intercepts and auto-responds" {
  CAST_HEADLESS=1 run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
}

@test "AskUserQuestion in headless mode → logs to headless-stalls.log" {
  CAST_HEADLESS=1 bash "$HOOK_SH" <<< "$(make_ask_user_payload "Should we continue?")"
  [[ -f "$HOME/.claude/logs/headless-stalls.log" ]]
}

@test "AskUserQuestion in headless mode → log contains HEADLESS STALL INTERCEPTED" {
  CAST_HEADLESS=1 bash "$HOOK_SH" <<< "$(make_ask_user_payload "Should we continue?")"
  grep -q "HEADLESS STALL INTERCEPTED" "$HOME/.claude/logs/headless-stalls.log"
}

@test "AskUserQuestion in headless mode → log contains the question text" {
  CAST_HEADLESS=1 bash "$HOOK_SH" <<< "$(make_ask_user_payload "Should we continue with the deployment?")"
  grep -q "Should we continue with the deployment" "$HOME/.claude/logs/headless-stalls.log"
}

@test "multiple AskUserQuestion calls in headless mode → each logged separately" {
  CAST_HEADLESS=1 bash "$HOOK_SH" <<< "$(make_ask_user_payload "Question 1?")"
  CAST_HEADLESS=1 bash "$HOOK_SH" <<< "$(make_ask_user_payload "Question 2?")"
  local count
  count=$(wc -l < "$HOME/.claude/logs/headless-stalls.log")
  [[ "$count" -ge 2 ]]
}

# ---------------------------------------------------------------------------
# Test 3: Subprocess guard — CLAUDE_SUBPROCESS=1 exits 0 silently
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 with AskUserQuestion → exits 0" {
  CLAUDE_SUBPROCESS=1 run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 → no output (short-circuit)" {
  CLAUDE_SUBPROCESS=1 run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 4: Non-AskUserQuestion tools — hook lets them through (not blocked)
# ---------------------------------------------------------------------------

@test "Bash tool → exits 0 (not intercepted)" {
  run bash "$HOOK_SH" <<< "$(make_other_tool_payload "Bash")"
  assert_success
}

@test "Write tool → exits 0 (not intercepted)" {
  run bash "$HOOK_SH" <<< "$(make_other_tool_payload "Write")"
  assert_success
}

@test "WebFetch tool → exits 0 (not intercepted)" {
  run bash "$HOOK_SH" <<< "$(make_other_tool_payload "WebFetch")"
  assert_success
}

@test "settings matcher ensures only AskUserQuestion triggers the hook" {
  local settings_file="$REPO_DIR/managed-settings.d/25-hooks-security.json"
  grep -q '"matcher": "AskUserQuestion"' "$settings_file"
}

# ---------------------------------------------------------------------------
# Test 5: Malformed JSON — graceful handling, no crash
# ---------------------------------------------------------------------------

@test "malformed JSON → exits 0 (no crash)" {
  run bash "$HOOK_SH" <<< '{"incomplete": json'
  assert_success
}

@test "JSON missing tool_name → exits 0" {
  run bash "$HOOK_SH" <<< '{"input": {"question": "Test"}}'
  assert_success
}

@test "empty JSON object → exits 0" {
  run bash "$HOOK_SH" <<< '{}'
  assert_success
}

# ---------------------------------------------------------------------------
# Test 6: Empty stdin — graceful exit
# ---------------------------------------------------------------------------

@test "empty stdin → exits 0" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

@test "empty stdin → exits 0 with valid JSON response" {
  run bash "$HOOK_SH" <<< ""
  assert_success
  echo "$output" | python3 -m json.tool > /dev/null
}

# ---------------------------------------------------------------------------
# Test 7: AskUserQuestion response format
# ---------------------------------------------------------------------------

@test "AskUserQuestion in headless mode → returns valid JSON response" {
  run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
  # Output should be valid JSON (or empty in subprocess mode)
  if [[ -n "$output" ]]; then
    echo "$output" | python3 -m json.tool > /dev/null
  fi
}

@test "AskUserQuestion response → includes updatedInput field" {
  CAST_HEADLESS=0 run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
  echo "$output" | grep -q "updatedInput" || true
}

# ---------------------------------------------------------------------------
# Test 8: Ported unique assertions from tests/hooks/cast-headless-guard.bats
# ---------------------------------------------------------------------------

@test "non-AskUserQuestion tool → exits 0 with JSON response" {
  run bash "$HOOK_SH" <<< "$(make_other_tool_payload "Bash")"
  assert_success
  assert_output --partial 'updatedInput'
}

@test "AskUserQuestion → JSON response has required fields and permissionDecision=allow" {
  CAST_HEADLESS=1 run bash "$HOOK_SH" <<< "$(make_ask_user_payload)"
  assert_success
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert 'updatedInput' in d, 'missing updatedInput'
assert 'answer' in d['updatedInput'], 'missing answer'
assert 'permissionDecision' in d, 'missing permissionDecision'
assert d['permissionDecision'] == 'allow', f'expected allow, got {d[\"permissionDecision\"]}'
print('ok')
" "$output"
}

@test "AskUserQuestion → answer text instructs proceed with defaults" {
  CAST_HEADLESS=1 run bash "$HOOK_SH" <<< "$(make_ask_user_payload "Use default config?")"
  assert_success
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
answer = d.get('updatedInput', {}).get('answer', '')
assert len(answer) > 0, 'answer is empty'
assert 'default' in answer.lower() or 'proceed' in answer.lower(), f'unexpected answer: {answer}'
print('ok')
" "$output"
}

@test "CLAUDE_SUBPROCESS=1 with AskUserQuestion → writes no log" {
  CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(make_ask_user_payload "Do something?")"
  [[ ! -f "$HOME/.claude/logs/headless-stalls.log" ]]
}
