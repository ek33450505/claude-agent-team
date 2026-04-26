#!/usr/bin/env bats
# Regression tests for cast-stat-claim-guard.sh
# Covers: SC2123 PATH clobber fix + stdin read fix (CAST_INPUT pattern)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GUARD="$REPO_DIR/scripts/cast-stat-claim-guard.sh"

# Get the real test count the same way the script does
setup() {
  REAL_COUNT=$(git -C "$REPO_DIR" ls-files 'tests/*.bats' 2>/dev/null | grep -vc 'tests/bats/' || echo "0")
  export CLAUDE_SUBPROCESS=0
}

# ---------------------------------------------------------------------------
# Blocking cases
# ---------------------------------------------------------------------------

@test "blocks Write to README.md with wrong badge count" {
  run bash "$GUARD" <<< '{"tool_name":"Write","tool_input":{"file_path":"/tmp/README.md","content":"![tests](https://img.shields.io/badge/tests-99999-green)"}}'
  assert_failure
  assert_equal "$status" 2
  assert_output --partial "Badge claims 99999 tests"
}

@test "blocks Edit to README.md with wrong badge count" {
  run bash "$GUARD" <<< '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/README.md","new_string":"![tests](https://img.shields.io/badge/tests-99999-green)"}}'
  assert_failure
  assert_equal "$status" 2
}

# ---------------------------------------------------------------------------
# Allow cases
# ---------------------------------------------------------------------------

@test "allows Write to README.md when badge count matches real count" {
  run bash "$GUARD" <<< "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/README.md\",\"content\":\"![tests](https://img.shields.io/badge/tests-${REAL_COUNT}-green)\"}}"
  assert_success
}

@test "allows pass-through for Read tool regardless of content" {
  run bash "$GUARD" <<< '{"tool_name":"Read","tool_input":{"file_path":"/tmp/README.md","content":"![tests](https://img.shields.io/badge/tests-99999-green)"}}'
  assert_success
}

@test "allows pass-through for non-README file path" {
  run bash "$GUARD" <<< '{"tool_name":"Write","tool_input":{"file_path":"/tmp/foo.txt","content":"![tests](https://img.shields.io/badge/tests-99999-green)"}}'
  assert_success
}

@test "allows Write to README.md with no badge in content" {
  run bash "$GUARD" <<< '{"tool_name":"Write","tool_input":{"file_path":"/tmp/README.md","content":"Just some normal README text"}}'
  assert_success
}

@test "allows pass-through when CLAUDE_SUBPROCESS=1" {
  CLAUDE_SUBPROCESS=1 run bash "$GUARD" <<< '{"tool_name":"Write","tool_input":{"file_path":"/tmp/README.md","content":"![tests](https://img.shields.io/badge/tests-99999-green)"}}'
  assert_success
}

# ---------------------------------------------------------------------------
# PATH regression — SC2123
# Verifies the script does not clobber the shell PATH env var.
# On the unfixed script, PATH="" causes 'git' not found and set -e exits 1.
# ---------------------------------------------------------------------------

@test "PATH env var is not clobbered by the script (SC2123 regression)" {
  # The wrong-count case requires git to succeed; if PATH were clobbered,
  # git ls-files would fail and set -e would exit 1 rather than 2.
  run bash "$GUARD" <<< '{"tool_name":"Write","tool_input":{"file_path":"/tmp/README.md","content":"![tests](https://img.shields.io/badge/tests-99999-green)"}}'
  # Must exit 2 (blocked), NOT 1 (git-not-found crash)
  assert_equal "$status" 2
}
