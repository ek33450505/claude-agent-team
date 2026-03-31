#!/usr/bin/env bats
# tests/hooks/cast-headless-guard.bats — Phase 4 headless guard tests
# Covers: cast-headless-guard.sh PreToolUse hook for AskUserQuestion interception

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

HOOK="$HOME/.claude/scripts/cast-headless-guard.sh"

# ── Payload helpers ──────────────────────────────────────────────────────────

make_ask_user_question_payload() {
  local question="${1:-Should I proceed with the default configuration?}"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'AskUserQuestion',
    'input': {
        'question': sys.argv[1],
    },
}))
" "$question"
}

make_non_question_payload() {
  local tool="${1:-Bash}"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': sys.argv[1],
    'input': {
        'command': 'echo hello',
    },
}))
" "$tool"
}

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/logs"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ═══════════════════════════════════════════════════════════════════════════════
# cast-headless-guard.sh tests
# ═══════════════════════════════════════════════════════════════════════════════

# 1. Exits 0 when tool_name is NOT AskUserQuestion
@test "headless-guard: non-AskUserQuestion tool → exits 0, no output" {
  run bash "$HOOK" <<< "$(make_non_question_payload "Bash")"
  assert_success
  assert_output ""
}

# 2. Exits 0 and prints valid JSON when tool_name IS AskUserQuestion
@test "headless-guard: AskUserQuestion → exits 0 and returns valid JSON" {
  run bash "$HOOK" <<< "$(make_ask_user_question_payload)"
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

# 3. Handles malformed JSON in input without crashing
@test "headless-guard: malformed JSON input → exits 0 without crashing" {
  run bash "$HOOK" <<< "not-valid-json{{{"
  assert_success
}

# 4. Handles empty input without crashing
@test "headless-guard: empty input → exits 0 without crashing" {
  run bash "$HOOK" <<< ""
  assert_success
}

# 5. Log file is written when AskUserQuestion is intercepted
@test "headless-guard: AskUserQuestion → writes to headless-stalls.log" {
  local question="What branch should I use?"
  bash "$HOOK" <<< "$(make_ask_user_question_payload "$question")"
  [ -f "$HOME/.claude/logs/headless-stalls.log" ]
  grep -q "HEADLESS STALL INTERCEPTED" "$HOME/.claude/logs/headless-stalls.log"
}

# 6. Log entry contains the intercepted question text
@test "headless-guard: log entry contains the question text" {
  local question="Should I overwrite existing files?"
  bash "$HOOK" <<< "$(make_ask_user_question_payload "$question")"
  grep -q "$question" "$HOME/.claude/logs/headless-stalls.log"
}

# 7. Non-AskUserQuestion tool does NOT write to stalls log
@test "headless-guard: Write tool → does NOT write to headless-stalls.log" {
  bash "$HOOK" <<< "$(make_non_question_payload "Write")"
  [ ! -f "$HOME/.claude/logs/headless-stalls.log" ]
}

# 8. Returns permissionDecision: allow for AskUserQuestion
@test "headless-guard: AskUserQuestion → permissionDecision is allow" {
  run bash "$HOOK" <<< "$(make_ask_user_question_payload "Continue?")"
  assert_success
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d.get('permissionDecision') == 'allow'
print('ok')
" "$output"
}

# 9. Answer text instructs agent to proceed with defaults
@test "headless-guard: AskUserQuestion → answer instructs proceed with defaults" {
  run bash "$HOOK" <<< "$(make_ask_user_question_payload "Use default config?")"
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

# 10. Hook is a no-op when CLAUDE_SUBPROCESS=1
@test "headless-guard: CLAUDE_SUBPROCESS=1 → exits 0, writes nothing" {
  CLAUDE_SUBPROCESS=1 bash "$HOOK" <<< "$(make_ask_user_question_payload "Do something?")"
  [ ! -f "$HOME/.claude/logs/headless-stalls.log" ]
}
