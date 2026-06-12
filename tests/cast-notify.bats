#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
NOTIFY_SH="$REPO_DIR/scripts/cast-notify.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Setup temp HOME for isolation
setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/cast"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Help flag tests
# ---------------------------------------------------------------------------

@test "cast-notify.sh --help exits 0" {
  run bash "$NOTIFY_SH" --help
  [ "$status" -eq 0 ]
}

@test "cast-notify.sh --help output contains Usage:" {
  run bash "$NOTIFY_SH" --help
  assert_output --partial "Usage:"
}

@test "cast-notify.sh -h exits 0" {
  run bash "$NOTIFY_SH" -h
  [ "$status" -eq 0 ]
}

@test "cast-notify.sh -h output contains Usage:" {
  run bash "$NOTIFY_SH" -h
  assert_output --partial "Usage:"
}

# ---------------------------------------------------------------------------
# Event type validation
# ---------------------------------------------------------------------------

@test "cast-notify.sh with no args exits 0" {
  run bash "$NOTIFY_SH"
  [ "$status" -eq 0 ]
}

@test "cast-notify.sh blocked event exits 0" {
  run bash "$NOTIFY_SH" blocked "Test message"
  [ "$status" -eq 0 ]
}

@test "cast-notify.sh queue_complete event exits 0" {
  run bash "$NOTIFY_SH" queue_complete
  [ "$status" -eq 0 ]
}
