#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-filechanged-hook.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  unset CLAUDE_SUBPROCESS
}

teardown() {
  teardown_temp_home
}

@test "filechanged hook: empty input exits 0" {
  run bash -c "echo '' | bash $SCRIPT"
  assert_success
}

@test "filechanged hook: malformed JSON exits 0 (graceful)" {
  run bash -c "echo 'not-json' | bash $SCRIPT"
  assert_success
}

@test "filechanged hook: valid JSON with file_path and change_type exits 0" {
  run bash -c 'echo "{\"file_path\":\"/repo/.envrc\",\"change_type\":\"modified\"}" | bash '"$SCRIPT"
  assert_success
}

