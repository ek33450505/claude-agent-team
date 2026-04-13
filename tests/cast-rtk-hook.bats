#!/usr/bin/env bats
# Tests for cast-rtk-hook.sh — RTK token compression PreToolUse hook

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cast-rtk-hook.sh"

@test "cast-rtk-hook: CLAUDE_SUBPROCESS=1 exits 0 with no output" {
  CLAUDE_SUBPROCESS=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cast-rtk-hook: empty input exits 0" {
  run bash "$SCRIPT" <<< ""
  [ "$status" -eq 0 ]
}

@test "cast-rtk-hook: rtk not in PATH passes input through unchanged" {
  # Ensure rtk is not found by using a restricted PATH
  INPUT='{"tool_name":"Read","output":"hello world"}'
  PATH="/usr/bin:/bin" run bash -c "echo '$INPUT' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello world"* ]]
}

@test "cast-rtk-hook: valid JSON input with rtk absent returns same JSON" {
  INPUT='{"key":"value","data":[1,2,3]}'
  PATH="/usr/bin:/bin" run bash -c "echo '$INPUT' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"key":"value"'* ]]
}

@test "cast-rtk-hook: script is executable" {
  [ -x "$SCRIPT" ]
}
