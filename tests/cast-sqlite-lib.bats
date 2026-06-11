#!/usr/bin/env bats
# Regression test for cast-sqlite-lib.sh
# Verifies that cast_sqlite() does NOT leak a stray "5000" line to stdout when
# setting the busy-timeout (regression: PRAGMA busy_timeout=5000 printed its
# return value on every call; fixed by switching to the silent .timeout dot-cmd).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$REPO_DIR/scripts/cast-sqlite-lib.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export TEST_DB="$(mktemp /tmp/cast-sqlite-lib-test-XXXXXX.db)"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Regression: no stray "5000" in inline-SQL output
# ---------------------------------------------------------------------------
@test "cast_sqlite inline mode: no stray 5000 on stdout" {
  run bash -c "source \"$LIB\"; cast_sqlite \"$TEST_DB\" 'SELECT 42;'"
  assert_success
  # Must not contain "5000" — the old PRAGMA return value
  refute_output --partial "5000"
}

@test "cast_sqlite inline mode: returns correct query result" {
  run bash -c "source \"$LIB\"; cast_sqlite \"$TEST_DB\" 'SELECT 42;'"
  assert_success
  assert_output "42"
}

# ---------------------------------------------------------------------------
# Regression: no stray "5000" in stdin/heredoc output
# ---------------------------------------------------------------------------
@test "cast_sqlite stdin mode: no stray 5000 on stdout" {
  run bash -c "printf 'SELECT 7;\n' | source \"$LIB\" 2>/dev/null; printf 'SELECT 7;\n' | bash -c 'source \"$LIB\"; cast_sqlite \"$TEST_DB\"'"
  assert_success
  refute_output --partial "5000"
}

@test "cast_sqlite stdin mode: returns correct query result" {
  run bash -c "printf 'SELECT 7;\n' | bash -c 'source \"$LIB\"; cast_sqlite \"$TEST_DB\"'"
  assert_success
  assert_output "7"
}

# ---------------------------------------------------------------------------
# Functional: busy-timeout is still wired (dot-cmd sets it correctly)
# ---------------------------------------------------------------------------
@test "cast_sqlite: .timeout sets PRAGMA busy_timeout to 5000" {
  run bash -c "source \"$LIB\"; cast_sqlite \"$TEST_DB\" 'PRAGMA busy_timeout;'"
  assert_success
  assert_output "5000"
}
