#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-cwdchanged-hook.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
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

@test "cwdchanged hook: CLAUDE_SUBPROCESS=1 short-circuits" {
  CLAUDE_SUBPROCESS=1 run bash -c "echo '{}' | bash $SCRIPT"
  assert_success
}
