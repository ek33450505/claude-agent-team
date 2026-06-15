#!/usr/bin/env bats
# Tests for scripts/check-plugin-drift.sh
# CI gate: verifies the committed plugin/ is not stale vs. regenerated output.
# All drift-detection tests run against an isolated copy — the real plugin/ is
# never written to, keeping the repo tree clean.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "check-plugin-drift.sh exits 0 on a clean run (no drift)" {
  run bash "$REPO_DIR/scripts/check-plugin-drift.sh"
  assert_success
  assert_output --partial "no drift"
}

@test "check-plugin-drift.sh reports 0 failed checks on clean run" {
  run bash "$REPO_DIR/scripts/check-plugin-drift.sh"
  assert_success
  assert_output --partial "0 failed"
}

@test "check-plugin-drift.sh detects drift when an extra file exists (hermetic)" {
  PLUGIN_COPY="$BATS_TEST_TMPDIR/plugin_copy"
  cp -r "$REPO_DIR/plugin" "$PLUGIN_COPY"
  touch "$PLUGIN_COPY/__probe__.txt"

  CAST_PLUGIN_DIR="$PLUGIN_COPY" run bash "$REPO_DIR/scripts/check-plugin-drift.sh"
  assert_failure
  assert_output --partial "STALE"
}

@test "real repo plugin/ is never polluted by drift test" {
  PLUGIN_COPY="$BATS_TEST_TMPDIR/plugin_copy"
  cp -r "$REPO_DIR/plugin" "$PLUGIN_COPY"
  touch "$PLUGIN_COPY/__probe__.txt"

  CAST_PLUGIN_DIR="$PLUGIN_COPY" run bash "$REPO_DIR/scripts/check-plugin-drift.sh"
  # The above run is expected to fail due to probe; we don't assert_failure here
  # because we only care about repo cleanliness below.

  run git -C "$REPO_DIR" status --short -- plugin/
  refute_output --partial "__probe__"
}
