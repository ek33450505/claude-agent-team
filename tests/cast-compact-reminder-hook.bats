#!/usr/bin/env bats
# Tests for cast-compact-reminder-hook.sh — compact reminder PostToolUse hook

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cast-compact-reminder-hook.sh"

setup() {
  export TEST_STATE_DIR
  TEST_STATE_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_STATE_DIR"
}

@test "cast-compact-reminder-hook: CLAUDE_SUBPROCESS=1 exits 0 with no output" {
  CLAUDE_SUBPROCESS=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cast-compact-reminder-hook: empty input exits 0" {
  run bash "$SCRIPT" <<< ""
  [ "$status" -eq 0 ]
}

@test "cast-compact-reminder-hook: invalid JSON exits 0" {
  run bash "$SCRIPT" <<< "not json"
  [ "$status" -eq 0 ]
}

@test "cast-compact-reminder-hook: increments counter on valid JSON input" {
  SESSION_ID="test-session-$$"
  INPUT="{\"session_id\":\"$SESSION_ID\"}"

  # Run once
  run bash -c "echo '$INPUT' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]

  # Verify counter file was created
  COUNTER_FILE="$HOME/.claude/cast/compact-state/${SESSION_ID}.count"
  [ -f "$COUNTER_FILE" ]
  COUNT=$(cat "$COUNTER_FILE")
  [ "$COUNT" -eq 1 ]

  # Cleanup
  rm -f "$COUNTER_FILE"
}

@test "cast-compact-reminder-hook: no output below threshold" {
  SESSION_ID="test-below-$$"
  INPUT="{\"session_id\":\"$SESSION_ID\"}"

  run bash -c "echo '$INPUT' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Cleanup
  rm -f "$HOME/.claude/cast/compact-state/${SESSION_ID}.count"
}

@test "cast-compact-reminder-hook: fires reminder at threshold 40" {
  SESSION_ID="test-threshold-$$"
  COUNTER_FILE="$HOME/.claude/cast/compact-state/${SESSION_ID}.count"

  # Pre-set counter to 39
  mkdir -p "$HOME/.claude/cast/compact-state"
  echo "39" > "$COUNTER_FILE"

  INPUT="{\"session_id\":\"$SESSION_ID\"}"
  run bash -c "echo '$INPUT' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compact_reminder"* ]]
  [[ "$output" == *"40 tool calls"* ]]

  # Cleanup
  rm -f "$COUNTER_FILE"
}

@test "cast-compact-reminder-hook: no reminder at 41 (only fires at exactly 40)" {
  SESSION_ID="test-past-threshold-$$"
  COUNTER_FILE="$HOME/.claude/cast/compact-state/${SESSION_ID}.count"

  # Pre-set counter to 40
  mkdir -p "$HOME/.claude/cast/compact-state"
  echo "40" > "$COUNTER_FILE"

  INPUT="{\"session_id\":\"$SESSION_ID\"}"
  run bash -c "echo '$INPUT' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Cleanup
  rm -f "$COUNTER_FILE"
}

@test "cast-compact-reminder-hook: script is executable" {
  [ -x "$SCRIPT" ]
}
