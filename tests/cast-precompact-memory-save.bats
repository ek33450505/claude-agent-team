#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cast-precompact-memory-save.sh"

setup() {
  # Create temp dirs for testing
  export TMPDIR="/tmp/bats-precompact-$$"
  mkdir -p "$TMPDIR"

  # Mock home for isolated testing
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME/.claude/agent-memory-local/session-snapshots"
  mkdir -p "$HOME/.claude/logs"
}

teardown() {
  # Clean up temp dirs
  rm -rf "$TMPDIR"
}

@test "subprocess guard exits 0 when CLAUDE_SUBPROCESS=1" {
  run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT" <<< '{}'
  [ "$status" -eq 0 ]
}

@test "script exits 0 with empty stdin (normal fire)" {
  run bash "$SCRIPT" <<< ''
  [ "$status" -eq 0 ]
}

@test "script exits 0 with malformed JSON" {
  run bash "$SCRIPT" <<< '{ invalid json }'
  [ "$status" -eq 0 ]
}

@test "script outputs allow decision JSON on stdout" {
  run bash "$SCRIPT" <<< ''
  [ "$status" -eq 0 ]
  [[ "$output" =~ "allow" ]]
}

@test "script creates snapshot file when given valid summary in JSON" {
  local input='{"summary":"This is a test session summary"}'
  run bash "$SCRIPT" <<< "$input"
  [ "$status" -eq 0 ]

  # Check that a snapshot file was created
  snapshot_count=$(find "$HOME/.claude/agent-memory-local/session-snapshots" -name "*.md" 2>/dev/null | wc -l)
  [ "$snapshot_count" -ge 1 ]
}

@test "snapshot file contains summary content" {
  local input='{"summary":"Important session context"}'
  bash "$SCRIPT" <<< "$input"

  # Read the created snapshot
  local snapshot_file=$(ls "$HOME/.claude/agent-memory-local/session-snapshots"/*.md 2>/dev/null | head -1)
  [ -f "$snapshot_file" ]
  grep -q "Important session context" "$snapshot_file"
}

@test "logs success to precompact-memory-save.log on valid summary" {
  local input='{"summary":"Test summary for logging"}'
  bash "$SCRIPT" <<< "$input"

  # Check that log file exists and contains INFO message
  [ -f "$HOME/.claude/logs/precompact-memory-save.log" ]
  grep -q "INFO" "$HOME/.claude/logs/precompact-memory-save.log"
}

@test "does not crash on null stdin" {
  run bash "$SCRIPT" <<< 'null'
  [ "$status" -eq 0 ]
}

@test "preserves summary with newlines" {
  local input='{"summary":"Line 1\nLine 2\nLine 3"}'
  bash "$SCRIPT" <<< "$input"

  local snapshot_file=$(ls "$HOME/.claude/agent-memory-local/session-snapshots"/*.md 2>/dev/null | head -1)
  [ -f "$snapshot_file" ]
  # Should have at least 3 lines (header + blank + summary)
  [ $(wc -l < "$snapshot_file") -ge 3 ]
}
