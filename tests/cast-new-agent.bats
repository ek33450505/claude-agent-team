#!/usr/bin/env bats
# Tests for `cast new-agent` subcommand (_cmd_new_agent in bin/cast)
#
# Coverage:
#   1. Creates ~/.claude/agents/<name>.md with correct frontmatter
#   2. Second run exits 1 with "Agent already exists"
#   3. Path traversal name exits 1 with validation error
#   4. No name argument exits 1 with usage message

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_ROOT/bin/cast"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/agents"
}

teardown() {
  teardown_temp_home
}

@test "creates ~/.claude/agents/<name>.md with correct frontmatter" {
  run bash "$CAST_CLI" new-agent myagent
  assert_success
  assert [ -f "$HOME/.claude/agents/myagent.md" ]

  local content
  content="$(cat "$HOME/.claude/agents/myagent.md")"
  assert echo "$content" | grep -q "name: myagent"
  assert echo "$content" | grep -q "model: haiku"
  assert echo "$content" | grep -q "# myagent"
}

@test "second run exits 1 with 'Agent already exists'" {
  bash "$CAST_CLI" new-agent myagent >/dev/null 2>&1

  run bash "$CAST_CLI" new-agent myagent
  assert_failure
  assert_output --partial "Agent already exists"
}

@test "path traversal name exits 1 with validation error" {
  run bash "$CAST_CLI" new-agent "../etc/passwd"
  assert_failure
  assert_output --partial "alphanumeric with hyphens only"
}

@test "no name argument exits 1 with usage message" {
  run bash "$CAST_CLI" new-agent
  assert_failure
  assert_output --partial "Usage: cast new-agent <name>"
}
