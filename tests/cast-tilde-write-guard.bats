#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/write-guards.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_payload() {
  local tool_name="$1"
  local file_path="$2"
  python3 -c "
import json, sys
tool = sys.argv[1]
fp   = sys.argv[2]
print(json.dumps({'tool_name': tool, 'tool_input': {'file_path': fp}}))
" "$tool_name" "$file_path"
}

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

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

@test "file_path with /~/ segment → exit 2 and stderr contains BLOCKED and corrected path" {
  local payload
  payload="$(make_payload "Write" "/Users/testuser/Desktop/~/.claude/plans/foo.md")"
  run bash "$HOOK_SH" <<< "$payload"
  assert_failure
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"$HOME/.claude/plans/foo.md"* ]]
}

@test "file_path ending in /~ (no trailing segment) → exit 2, BLOCKED, corrected path is exactly HOME" {
  local payload
  payload="$(make_payload "Write" "/Users/testuser/Desktop/~")"
  run bash "$HOOK_SH" <<< "$payload"
  assert_failure
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"BLOCKED"* ]]
  # Corrected path must be $HOME exactly — not a double-slash or $HOME/$HOME variant
  [[ "$output" == *"Likely intended: $HOME"* ]]
  [[ "$output" != *"Likely intended: $HOME/$HOME"* ]]
  [[ "$output" != *"//"* ]]
}

@test "canonical absolute path → exit 0 no block" {
  local payload
  payload="$(make_payload "Write" "/tmp/foo.md")"
  run bash "$HOOK_SH" <<< "$payload"
  assert_success
}

@test "leading ~/foo (normal model output, no preceding slash) → exit 0 no block" {
  local payload
  payload="$(make_payload "Write" "~/foo/bar.md")"
  run bash "$HOOK_SH" <<< "$payload"
  assert_success
}

@test "empty stdin → exit 0 no crash" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 → exit 0 even with literal-tilde path" {
  export CLAUDE_SUBPROCESS=1
  local payload
  payload="$(make_payload "Write" "/Users/testuser/Desktop/~/.claude/plans/foo.md")"
  run bash "$HOOK_SH" <<< "$payload"
  assert_success
}

@test "invalid JSON stdin → exit 0 no crash" {
  run bash "$HOOK_SH" <<< "not valid json {"
  assert_success
}
