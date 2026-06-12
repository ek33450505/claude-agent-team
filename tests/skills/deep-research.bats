#!/usr/bin/env bats
# tests/skills/deep-research.bats
# Thin BATS wrapper around the standalone regression harness for deep-research.
# Guards PR #133 honesty fix: rate-limited/StructuredOutput-fail verify outcomes
# must map to `unverified`, NOT `refuted`.
# This test does NOT touch $HOME.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HARNESS="$REPO_DIR/skills/deep-research/deep-research.verify.cjs"

@test "deep-research harness exists at expected path" {
  [ -f "$HARNESS" ]
}

@test "deep-research regression scenarios all pass (honesty fix PR #133)" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  run node "$HARNESS"
  assert_success
  assert_output --partial "ALL CHECKS PASSED"
}
