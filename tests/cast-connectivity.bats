#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CONNECTIVITY_SH="$REPO_DIR/scripts/cast-connectivity.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_OFFLINE_QUEUE_DIR="$HOME/.claude/cast/offline-queue"
  mkdir -p "$HOME/.claude/cast"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "cast-connectivity.sh: no args prints usage and exits 1" {
  run bash "$CAST_CONNECTIVITY_SH"
  assert_failure
  assert_output --partial "Usage:"
}

@test "cast-connectivity.sh: --help prints usage and exits 0" {
  run bash "$CAST_CONNECTIVITY_SH" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Commands:"
}

@test "cast-connectivity.sh: unknown command exits 1" {
  run bash "$CAST_CONNECTIVITY_SH" bogus
  assert_failure
  assert_output --partial "Unknown command"
}

@test "cast-connectivity.sh: check returns 0 or 1 with online/offline" {
  run bash "$CAST_CONNECTIVITY_SH" check
  # Either online (0) or offline (1) — both are valid
  [[ "$status" -eq 0 || "$status" -eq 1 ]]
  [[ "$output" == "online" || "$output" == "offline" ]]
}

@test "cast-connectivity.sh: queue creates a JSON file" {
  run bash "$CAST_CONNECTIVITY_SH" queue "test-agent" "test task description"
  assert_success
  assert_output --partial "Queued task"

  # Verify file was created
  FILE_COUNT=$(find "$CAST_OFFLINE_QUEUE_DIR" -name "*.json" -type f | wc -l | tr -d ' ')
  [ "$FILE_COUNT" -eq 1 ]
}

@test "cast-connectivity.sh: queue file contains correct JSON" {
  bash "$CAST_CONNECTIVITY_SH" queue "code-writer" "fix the bug"

  QUEUE_FILE=$(find "$CAST_OFFLINE_QUEUE_DIR" -name "*.json" -type f | head -1)
  [ -f "$QUEUE_FILE" ]

  # Verify JSON content
  AGENT=$(python3 -c "import json; d=json.load(open('$QUEUE_FILE')); print(d['agent'])")
  TASK=$(python3 -c "import json; d=json.load(open('$QUEUE_FILE')); print(d['task'])")
  [ "$AGENT" = "code-writer" ]
  [ "$TASK" = "fix the bug" ]
}

@test "cast-connectivity.sh: queue requires agent and task" {
  run bash "$CAST_CONNECTIVITY_SH" queue
  assert_failure
  assert_output --partial "requires"
}

@test "cast-connectivity.sh: status output includes expected sections" {
  run bash "$CAST_CONNECTIVITY_SH" status
  assert_success
  assert_output --partial "Network:"
  assert_output --partial "Offline queue:"
  assert_output --partial "Last replay:"
}
