#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

HOOK_SH="/Users/edkubiak/.claude/scripts/cast-user-prompt-hook.sh"

make_payload() {
  local session_id="${1:-test-session-001}"
  local prompt="${2:-Hello, what can you do?}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'UserPromptSubmit',
    'session_id': sys.argv[1],
    'prompt':     sys.argv[2],
}))
" "$session_id" "$prompt"
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
# 1. Happy path: valid JSON → exits 0
# ---------------------------------------------------------------------------

@test "valid UserPromptSubmit payload → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
}

# ---------------------------------------------------------------------------
# 2. Happy path: log entry created with correct fields
# ---------------------------------------------------------------------------

@test "valid payload → appends to user-prompts.jsonl with correct fields" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-prompt-1" "Tell me about CAST")"
  [ -f "$HOME/.claude/cast/user-prompts.jsonl" ]
  python3 -c "
import json
with open('$HOME/.claude/cast/user-prompts.jsonl') as f:
    d = json.loads(f.readline().strip())
assert d.get('session_id')     == 'sess-prompt-1',     f'session_id={d.get(\"session_id\")}'
assert d.get('prompt_preview') == 'Tell me about CAST', f'preview={d.get(\"prompt_preview\")}'
assert d.get('prompt_length')  == len('Tell me about CAST'), f'length={d.get(\"prompt_length\")}'
assert 'timestamp' in d, 'missing timestamp'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 3. CLAUDE_SUBPROCESS guard
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 → exits 0 and writes nothing" {
  CLAUDE_SUBPROCESS=1 run bash "$HOOK_SH" <<< "$(make_payload)"
  assert_success
  [ ! -f "$HOME/.claude/cast/user-prompts.jsonl" ]
}

# ---------------------------------------------------------------------------
# 4. Long prompt → prompt_preview capped at 120 chars
# ---------------------------------------------------------------------------

@test "prompt longer than 120 chars → prompt_preview capped at exactly 120" {
  local long_prompt
  long_prompt=$(python3 -c "print('A' * 200)")
  bash "$HOOK_SH" <<< "$(make_payload "sess-long" "$long_prompt")"
  python3 -c "
import json
with open('$HOME/.claude/cast/user-prompts.jsonl') as f:
    d = json.loads(f.readline().strip())
preview_len = len(d.get('prompt_preview', ''))
assert preview_len == 120, f'expected 120, got {preview_len}'
assert d.get('prompt_length') == 200, f'expected length 200, got {d.get(\"prompt_length\")}'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 5. Prompt exactly 120 chars → not truncated
# ---------------------------------------------------------------------------

@test "prompt exactly 120 chars → prompt_preview is full prompt" {
  local exact_prompt
  exact_prompt=$(python3 -c "print('B' * 120)")
  bash "$HOOK_SH" <<< "$(make_payload "sess-exact" "$exact_prompt")"
  python3 -c "
import json
with open('$HOME/.claude/cast/user-prompts.jsonl') as f:
    d = json.loads(f.readline().strip())
assert len(d.get('prompt_preview', '')) == 120, f'got {len(d.get(\"prompt_preview\",\"\"))}'
print('ok')
"
}

# ---------------------------------------------------------------------------
# 6. Invalid JSON → exits 0 (never crash or block session)
# ---------------------------------------------------------------------------

@test "invalid JSON input → exits 0 gracefully" {
  run bash "$HOOK_SH" <<< "{ broken json ]["
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

@test "two prompts → two lines in jsonl" {
  bash "$HOOK_SH" <<< "$(make_payload "sess-a" "first prompt")"
  bash "$HOOK_SH" <<< "$(make_payload "sess-b" "second prompt")"
  local lines
  lines=$(wc -l < "$HOME/.claude/cast/user-prompts.jsonl")
  [ "$lines" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 9. Special chars in prompt → handled safely
# ---------------------------------------------------------------------------

@test "prompt with quotes and special chars → exits 0 and logs" {
  local special_prompt="It's a \"test\" with \$pecial ch@rs & more"
  run bash "$HOOK_SH" <<< "$(make_payload "sess-special" "$special_prompt")"
  assert_success
  [ -f "$HOME/.claude/cast/user-prompts.jsonl" ]
}
