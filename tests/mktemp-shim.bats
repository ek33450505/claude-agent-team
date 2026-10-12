#!/usr/bin/env bats
# tests/mktemp-shim.bats
# Validates tests/helpers/bin/mktemp — the macOS shim that makes template-less
# and `-t prefix` mktemp calls honour $TMPDIR (BSD mktemp ignores it).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SHIM="$REPO_DIR/tests/helpers/bin/mktemp"

setup() {
  local base="${TMPDIR:-/tmp}"
  base="${base%/}"
  CUSTOM_TMP="$(mktemp -d "$base/mktemp-shim.XXXXXX")"
}

teardown() {
  # Destructive-path guard: only remove the dir setup() created directly under the temp base
  local base="${TMPDIR:-/tmp}"
  base="${base%/}"
  if [[ -n "${CUSTOM_TMP:-}" && -d "$CUSTOM_TMP" && "$(dirname -- "$CUSTOM_TMP")" == "$base" && "$CUSTOM_TMP" != *..* ]]; then
    rm -rf -- "$CUSTOM_TMP"
  fi
}

@test "template-less -d lands under custom TMPDIR" {
  run env TMPDIR="$CUSTOM_TMP" "$SHIM" -d
  assert_success
  [[ "$output" == "$CUSTOM_TMP/tmp."* ]]
  [ -d "$output" ]
}

@test "-t prefix lands under custom TMPDIR with prefix" {
  run env TMPDIR="$CUSTOM_TMP" "$SHIM" -d -t foo
  assert_success
  [[ "$output" == "$CUSTOM_TMP/foo."* ]]
  [ -d "$output" ]
}

@test "explicit template passes through unchanged" {
  run env TMPDIR=/nonexistent "$SHIM" -d "$CUSTOM_TMP/explicit.XXXXXX"
  assert_success
  [[ "$output" == "$CUSTOM_TMP/explicit."* ]]
  [ -d "$output" ]
}

@test "TMPDIR with trailing slash yields no double slash" {
  run env TMPDIR="$CUSTOM_TMP/" "$SHIM" -d
  assert_success
  [[ "$output" == "$CUSTOM_TMP/tmp."* ]]
  [[ "$output" != *//* ]]
}

@test "plain file is created without -d" {
  run env TMPDIR="$CUSTOM_TMP" "$SHIM"
  assert_success
  [[ "$output" == "$CUSTOM_TMP/tmp."* ]]
  [ -f "$output" ]
}

@test "-t without a value fails with usage error" {
  run env TMPDIR="$CUSTOM_TMP" "$SHIM" -d -t
  assert_failure 1
  assert_output --partial "usage"
  run ls -A "$CUSTOM_TMP"
  assert_output ""
}

@test "-- makes following dash-leading args templates" {
  cd "$CUSTOM_TMP"
  run env TMPDIR="$CUSTOM_TMP" "$SHIM" -- -foo.XXXXXX
  assert_success
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == -foo.* ]]
  [ -f "$CUSTOM_TMP/$output" ]
  run bash -c 'ls -A "$1"' _ "$CUSTOM_TMP"
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == -foo.* ]]
}

# Verifies run.sh's PATH wiring; skipped when run by plain bats (make test / CI), which bypasses run.sh.
@test "run.sh puts the shim first on PATH (Darwin)" {
  [[ "$(uname -s)" == Darwin ]] || skip "Darwin-only wiring"
  [[ "${CAST_TESTS_VIA_RUN_SH:-}" == 1 ]] || skip "not run via tests/run.sh (e.g. make test / CI bats)"
  [ "$(command -v mktemp)" = "$REPO_DIR/tests/helpers/bin/mktemp" ]
}
