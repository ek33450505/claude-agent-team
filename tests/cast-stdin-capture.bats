#!/usr/bin/env bats
# cast-stdin-capture.bats — opt-in raw-stdin capture in the SubagentStop hook.
#
# Coverage:
#   1. capture dir absent -> hook exits 0, no stdin-capture dir created
#   2. capture dir present -> exactly one *.json file, byte-identical to stdin
#   3. cap honoured -> CAST_STDIN_CAPTURE_MAX=1 with one pre-existing file stays at 1
#   4. capture failure (unwritable dir) is non-fatal -> hook still exits 0

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export TMPDIR="$HOME"
  CAPTURE_DIR="$HOME/.claude/cast/debug/stdin-capture"
}

teardown() {
  # Restore permissions in case a test left the dir locked down, so teardown can clean up.
  [ -d "$CAPTURE_DIR" ] && chmod 700 "$CAPTURE_DIR" 2>/dev/null || true
  teardown_temp_home
  unset TMPDIR
}

# ---------------------------------------------------------------------------
# 1. capture dir absent -> no-op
# ---------------------------------------------------------------------------

@test "capture dir absent: hook exits 0 and no stdin-capture dir is created" {
  payload='{"agent":"test-agent","status":"DONE"}'
  run bash -c "printf '%s' '$payload' | bash '$HOOK'"
  assert_success
  run find "$HOME/.claude" -type d -name "stdin-capture"
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 2. capture dir present -> exactly one file, byte-identical
# ---------------------------------------------------------------------------

@test "capture dir present: exactly one json file appears, byte-identical to stdin" {
  mkdir -p "$CAPTURE_DIR"
  payload='{"agent":"test-agent","status":"DONE","note":"hello world"}'
  run bash -c "printf '%s' '$payload' | bash '$HOOK'"
  assert_success

  local count
  count="$(find "$CAPTURE_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  [ "$count" = "1" ]

  local captured_file
  captured_file="$(find "$CAPTURE_DIR" -maxdepth 1 -type f -name '*.json')"
  local captured_content
  captured_content="$(cat "$captured_file")"
  [ "$captured_content" = "$payload" ]
}

# ---------------------------------------------------------------------------
# 3. cap honoured
# ---------------------------------------------------------------------------

@test "cap honoured: CAST_STDIN_CAPTURE_MAX=1 with one pre-existing file stays at 1" {
  mkdir -p "$CAPTURE_DIR"
  printf '%s' '{"pre":"existing"}' > "$CAPTURE_DIR/preexisting.json"

  local payload='{"agent":"test-agent","status":"DONE"}'
  local count

  # First, prove capture is actually ACTIVE (no cap override, default 500):
  # the pre-existing file must grow to 2 — this is what discriminates the cap
  # check from the feature being disabled entirely (a disabled feature would
  # leave count at 1 here too, making the final assertion pass vacuously).
  run bash -c "printf '%s' '$payload' | bash '$HOOK'"
  assert_success
  count="$(find "$CAPTURE_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  [ "$count" = "2" ]

  # Now with 2 files present and CAST_STDIN_CAPTURE_MAX=1, the cap check
  # (2 is not < 1) must block any further write — count stays at 2.
  run bash -c "printf '%s' '$payload' | CAST_STDIN_CAPTURE_MAX=1 bash '$HOOK'"
  assert_success
  count="$(find "$CAPTURE_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  [ "$count" = "2" ]
}

# ---------------------------------------------------------------------------
# 4. capture failure is non-fatal
# ---------------------------------------------------------------------------

@test "capture failure (unwritable dir) is non-fatal: hook still exits 0" {
  mkdir -p "$CAPTURE_DIR"
  chmod 500 "$CAPTURE_DIR"

  payload='{"agent":"test-agent","status":"DONE"}'
  run bash -c "printf '%s' '$payload' | bash '$HOOK'"
  assert_success

  chmod 700 "$CAPTURE_DIR"
}

# ---------------------------------------------------------------------------
# 5. malformed CAST_STDIN_CAPTURE_MAX degrades to the default, never to "off"
# ---------------------------------------------------------------------------

@test "malformed CAST_STDIN_CAPTURE_MAX falls back to the default instead of disabling capture" {
  mkdir -p "$CAPTURE_DIR"
  payload='{"agent":"test-agent","status":"DONE"}'

  run bash -c "printf '%s' '$payload' | CAST_STDIN_CAPTURE_MAX=abc bash '$HOOK' 2>&1"
  assert_success

  local count
  count="$(find "$CAPTURE_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  [ "$count" = "1" ]

  refute_output --partial 'integer expected'
}

# ---------------------------------------------------------------------------
# 6. overflow-sized CAST_STDIN_CAPTURE_MAX degrades to the default, never to "off"
# ---------------------------------------------------------------------------

@test "overflow-sized CAST_STDIN_CAPTURE_MAX falls back to the default instead of disabling capture" {
  mkdir -p "$CAPTURE_DIR"
  payload='{"agent":"test-agent","status":"DONE"}'

  run bash -c "printf '%s' '$payload' | CAST_STDIN_CAPTURE_MAX=99999999999999999999 bash '$HOOK' 2>&1"
  assert_success

  local count
  count="$(find "$CAPTURE_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  [ "$count" = "1" ]

  refute_output --partial 'integer expected'
}
