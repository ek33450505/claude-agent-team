#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-cwdchanged-hook.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  unset CLAUDE_SUBPROCESS
}

teardown() {
  teardown_temp_home
}

@test "cwdchanged hook: empty input exits 0" {
  run bash -c "echo '' | bash $SCRIPT"
  assert_success
}

@test "cwdchanged hook: malformed JSON exits 0 (graceful)" {
  run bash -c "echo 'not-json' | bash $SCRIPT"
  assert_success
}

@test "cwdchanged hook: valid JSON input exits 0" {
  run bash -c 'echo "{\"previous_cwd\":\"/tmp/a\",\"new_cwd\":\"/tmp/b\"}" | bash '"$SCRIPT"
  assert_success
}

