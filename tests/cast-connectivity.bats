#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CONNECTIVITY_SH="$REPO_DIR/scripts/cast-connectivity.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CAST_OFFLINE_QUEUE_DIR="$HOME/.claude/cast/offline-queue"
  mkdir -p "$HOME/.claude/cast"
}

teardown() {
  teardown_temp_home
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

@test "cast-connectivity.sh: replay treats a quote-bearing queue filename as data (no code injection)" {
  # PATH-shim ping so replay proceeds without touching the network
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/ping"
  chmod +x "$BATS_TEST_TMPDIR/bin/ping"

  mkdir -p "$CAST_OFFLINE_QUEUE_DIR"
  # Filename closes the python string literal and concatenates a payload that
  # genuinely executes under the old interpolated form: it writes a
  # relative-path sentinel into the process cwd before the outer open() fails.
  local evil="x'+str(open('pwned','w').write('1'))+'.json"
  printf '{"agent":"bash-specialist","task":"hello"}' > "$CAST_OFFLINE_QUEUE_DIR/$evil"

  cd "$BATS_TEST_TMPDIR"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$CAST_CONNECTIVITY_SH" replay
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  assert_output --partial "agent=bash-specialist task=hello"
  assert_output --partial "1 replayed, 0 failed"
}
