#!/usr/bin/env bats
# Tests for audit-context-size.sh — context line count audit

SCRIPT="$BATS_TEST_DIRNAME/../scripts/audit-context-size.sh"

setup() {
  export TEST_CLAUDE_DIR
  TEST_CLAUDE_DIR="$(mktemp -d)"
  mkdir -p "$TEST_CLAUDE_DIR/rules"
}

teardown() {
  rm -rf "$TEST_CLAUDE_DIR"
}

@test "audit-context-size: script exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "audit-context-size: known line count matches expected output" {
  # Create CLAUDE.md with exactly 10 lines
  for i in $(seq 1 10); do echo "line $i"; done > "$TEST_CLAUDE_DIR/CLAUDE.md"

  # Create a rules file with exactly 5 lines
  for i in $(seq 1 5); do echo "rule $i"; done > "$TEST_CLAUDE_DIR/rules/test.md"

  CLAUDE_DIR="$TEST_CLAUDE_DIR" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOTAL: 15 lines"* ]]
}

@test "audit-context-size: warns when total exceeds 500 lines" {
  # Create a CLAUDE.md with 501 lines
  for i in $(seq 1 501); do echo "line $i"; done > "$TEST_CLAUDE_DIR/CLAUDE.md"

  CLAUDE_DIR="$TEST_CLAUDE_DIR" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: exceeds 500-line recommendation"* ]]
}

@test "audit-context-size: prints OK when total is within limit" {
  # Create CLAUDE.md with 10 lines
  for i in $(seq 1 10); do echo "line $i"; done > "$TEST_CLAUDE_DIR/CLAUDE.md"

  CLAUDE_DIR="$TEST_CLAUDE_DIR" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: within recommended limit"* ]]
}

@test "audit-context-size: handles missing CLAUDE.md gracefully" {
  # No CLAUDE.md, just a rules file
  echo "rule" > "$TEST_CLAUDE_DIR/rules/test.md"

  CLAUDE_DIR="$TEST_CLAUDE_DIR" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOTAL: 1 lines"* ]]
}
