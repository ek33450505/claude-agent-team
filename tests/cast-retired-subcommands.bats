#!/usr/bin/env bats
# Retired subcommands refuse with a pointer, and completions no longer offer them.
# `cast exec` was retired in v10.8.0 (replaced by /orchestrate).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

@test "cast exec refuses with exit 2 and a pointer to /orchestrate" {
  run bash "$REPO_DIR/bin/cast" exec
  assert_failure 2
  assert_output --partial "cast exec was retired in v10.8.0; use /orchestrate"
}

@test "cast exec with arguments still refuses with exit 2" {
  run bash "$REPO_DIR/bin/cast" exec --resume foo.md
  assert_failure 2
  assert_output --partial "cast exec was retired in v10.8.0; use /orchestrate"
}

@test "exec is absent from the generated regions of completions/cast.bash" {
  run awk '/BEGIN GENERATED SUBCOMMANDS/{on=1;next} /END GENERATED SUBCOMMANDS/{on=0} on' "$REPO_DIR/completions/cast.bash"
  assert_success
  [ -n "$output" ]
  run bash -c 'awk "/BEGIN GENERATED SUBCOMMANDS/{on=1;next} /END GENERATED SUBCOMMANDS/{on=0} on" "$1" | grep -qw exec' _ "$REPO_DIR/completions/cast.bash"
  assert_failure
}

@test "exec is absent from the generated regions of completions/_cast" {
  run awk '/BEGIN GENERATED SUBCOMMANDS/{on=1;next} /END GENERATED SUBCOMMANDS/{on=0} on' "$REPO_DIR/completions/_cast"
  assert_success
  [ -n "$output" ]
  run bash -c 'awk "/BEGIN GENERATED SUBCOMMANDS/{on=1;next} /END GENERATED SUBCOMMANDS/{on=0} on" "$1" | grep -qw exec' _ "$REPO_DIR/completions/_cast"
  assert_failure
}

@test "cast --help no longer lists exec as a subcommand" {
  run bash "$REPO_DIR/bin/cast" --help
  assert_success
  assert_output --partial "parallel"
  stripped="$(printf '%s\n' "$output" | sed $'s/\x1b\\[[0-9;]*m//g')"
  run bash -c 'printf "%s\n" "$1" | grep -qE "^[[:space:]]*exec[[:space:]]"' _ "$stripped"
  assert_failure
}
