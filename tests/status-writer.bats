#!/usr/bin/env bats
# Regression test for scripts/status-writer.sh: `local status="$1"` collided with
# zsh's read-only special parameter `status` (same class as `$?`), breaking
# cast_write_status whenever the file was sourced under zsh. A bash-only BATS
# test would not catch this — must be exercised under a real zsh subshell.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STATUS_WRITER_SH="$REPO_DIR/scripts/status-writer.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; CAST_STATUS_DIR derives from $HOME
}

teardown() {
  teardown_temp_home
}

@test "cast_write_status succeeds under zsh (regression: 'status' is read-only in zsh)" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"

  run zsh -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'test summary' 'test-agent-zsh'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'test-agent-zsh-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]
  [ -f "$written" ]
}

@test "cast_write_status succeeds under bash (primary path still works)" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'test summary' 'test-agent-bash'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'test-agent-bash-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]
  [ -f "$written" ]
}

@test "written JSON file has correct status/summary/agent fields" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE_WITH_CONCERNS 'a summary here' 'field-check-agent'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'field-check-agent-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]

  run python3 -c "
import json
d = json.load(open('$written'))
assert d['status'] == 'DONE_WITH_CONCERNS', d
assert d['summary'] == 'a summary here', d
assert d['agent'] == 'field-check-agent', d
print('ok')
"
  assert_success
  assert_output "ok"
}
