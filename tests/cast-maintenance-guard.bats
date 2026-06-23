#!/usr/bin/env bats
# tests/cast-maintenance-guard.bats — Integration tests for cast-maintenance.sh guard behaviour.
#
# Tests SOURCE cast-maintenance.sh (source guard fires, skipping the main body)
# and exercise the cast-guard-lib.sh / cast_safe_rm refusal-tolerance path.
#
# Coverage:
#   1. cast_safe_rm refusal is non-fatal — || log pattern works (lib-level)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Isolate HOME so cast-maintenance.sh sets CAST_DIR to a temp path
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  # Source the real maintenance script — source guard stops before main execution
  # shellcheck disable=SC1090
  source "$REPO_DIR/scripts/cast-maintenance.sh"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. Refusal tolerance — cast_safe_rm refused path is logged, not fatal.
# ---------------------------------------------------------------------------
@test "cast_safe_rm refusal is non-fatal — || log pattern works (lib-level)" {
  local outside_dir
  outside_dir="$BATS_TEST_TMPDIR/outside-radius-$$"
  mkdir "$outside_dir"
  touch "$outside_dir/canary"

  # Declare a blast radius that doesn't include outside_dir
  cast_declare_blast_radius "/private/tmp/cast-guard-test-" "/tmp/cast-guard-test-"

  # Replicate the || log pattern — refusal must not propagate as error
  local result=0
  cast_safe_rm "$outside_dir" 2>/dev/null || result=$?
  [ "$result" -ne 0 ]            # refusal happened
  [ -f "$outside_dir/canary" ]   # target survived

  # Confirm the || tolerance: simulating a maintenance-style body with set -e active
  (
    set -euo pipefail
    cast_safe_rm "$outside_dir" 2>/dev/null || true   # mirrors: ... || log "WARN..."
  )
  # Still alive here → tolerance confirmed
  [ -f "$outside_dir/canary" ]
}
