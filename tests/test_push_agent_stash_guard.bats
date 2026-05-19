#!/usr/bin/env bats
# test_push_agent_stash_guard.bats
# Guards against regression of the 2026-05-19 push-agent stash bug:
#   push agent ran bare 'git stash pop/apply', resurrected an abandoned Wave-5 stash,
#   and wrote literal conflict markers into cast-desktop's App.tsx.
# Fix: pre-tool-guard.sh now blocks all 'git stash' invocations from Bash tool calls.

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

  # Unset all escape hatches to ensure clean state
  unset CLAUDE_SUBPROCESS
  unset CAST_STASH_OK
  unset CAST_PUSH_OK
  unset CAST_COMMIT_AGENT
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CLAUDE_DIR
}

# Helper: build a Bash tool payload for a given command
make_bash_payload() {
  local cmd="$1"
  python3 -c "
import json, sys
print(json.dumps({
  'tool_name': 'Bash',
  'tool_input': {
    'command': '$cmd',
    'description': 'test command'
  }
}))
" 2>/dev/null || echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
}

# ---------------------------------------------------------------------------
# Test 1: Bare 'git stash' is blocked (exit 2) — regression guard for
#         the 2026-05-19 incident where push agent stashed without CAST_STASH_OK
# ---------------------------------------------------------------------------

@test "pre-tool-guard blocks bare 'git stash' invocation (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git stash")"

  assert_failure  # exit code should be 2
  [ "$status" -eq 2 ]
  assert_output --partial "git stash"
  assert_output --partial "blocked"
}

# ---------------------------------------------------------------------------
# Test 2: 'git stash pop' is blocked — the exact form that caused the 2026-05-19 incident
# ---------------------------------------------------------------------------

@test "pre-tool-guard blocks 'git stash pop' invocation (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git stash pop")"

  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "git stash"
  assert_output --partial "blocked"
}

# ---------------------------------------------------------------------------
# Test 3: 'git stash apply' is blocked — the second form that caused the incident
# ---------------------------------------------------------------------------

@test "pre-tool-guard blocks 'git stash apply' invocation (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git stash apply")"

  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "git stash"
}

# ---------------------------------------------------------------------------
# Test 4: CAST_STASH_OK=1 escape hatch allows stash — for deliberate use
# ---------------------------------------------------------------------------

@test "pre-tool-guard allows 'git stash' with CAST_STASH_OK=1 escape hatch (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_STASH_OK=1 git stash push -u -m cast-baseline-123")"

  assert_success
}

# ---------------------------------------------------------------------------
# Test 5: CLAUDE_SUBPROCESS=1 allows stash — subprocess bypass applies
# ---------------------------------------------------------------------------

@test "pre-tool-guard allows 'git stash' from CLAUDE_SUBPROCESS=1 context (exit 0)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git stash list")"

  assert_success
}

# ---------------------------------------------------------------------------
# Test 6: Block message references the escape hatch so agents know how to proceed
# ---------------------------------------------------------------------------

@test "block message for 'git stash' references CAST_STASH_OK escape hatch" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git stash")"

  assert_failure
  assert_output --partial "CAST_STASH_OK=1"
}
