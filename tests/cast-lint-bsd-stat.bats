#!/usr/bin/env bats
# tests/cast-lint-bsd-stat.bats — gate-must-bite tests for scripts/cast-lint-bsd-stat.sh
# (bans the BSD-first stat fallback order in tests/: GNU `stat -f` succeeds, so the fallback
# never runs on Linux). Fixtures are written to mktemp dirs and scanned via CAST_LINT_TESTS_DIR;
# the real tests/ tree is never modified. Fixture lines are assembled so THIS file does not itself
# contain the banned pattern: @STAT@ in a fixture line is replaced by the word stat at runtime.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_SCRIPT="$REPO_DIR/scripts/cast-lint-bsd-stat.sh"

_fixture() {  # <name> <content-line>...
  local d="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$d"
  shift
  printf '%s\n' "${@//@STAT@/stat}" >"$d/case.bats"
  printf '%s\n' "$d"
}

@test "bsd-stat-lint flags the BSD-first fallback order" {
  local d
  d="$(_fixture bad '  m="$(@STAT@ -f %Lp "$f" 2>/dev/null || @STAT@ -c %a "$f")"')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "case.bats:1"
  assert_output --partial "file_mode"
}

@test "bsd-stat-lint flags the %-glued -f form and extra flags" {
  local d
  d="$(_fixture glued 'm=$(@STAT@ -L -f%Lp "$f" || @STAT@ -L -c%a "$f")')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
}

@test "bsd-stat-lint flags the backslash-continuation form" {
  local d
  d="$(_fixture cont 'm=$(@STAT@ -f %m "$f" \' '   || @STAT@ -c %Y "$f")')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "case.bats:1"
}

@test "bsd-stat-lint flags a line ending in || that continues on the next line" {
  local d
  d="$(_fixture orcont 'm=$(@STAT@ -f %m "$f" ||' '  @STAT@ -c %Y "$f")')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
}

@test "bsd-stat-lint flags a flag-cluster -Lf before the || fallback" {
  local d
  d="$(_fixture cluster 'm=$(@STAT@ -Lf %Lp "$f" || @STAT@ -c %a "$f")')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "case.bats:1"
}

@test "bsd-stat-lint flags a line ending in || followed by multiple trailing spaces" {
  local d
  d="$(_fixture orspaces 'm=$(@STAT@ -f %m "$f" ||   ' '  @STAT@ -c %Y "$f")')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "case.bats:1"
}

@test "bsd-stat-lint flags a continuation line that STARTS with ||" {
  local d
  d="$(_fixture orlead 'm=$(@STAT@ -f %m "$f"' '  || @STAT@ -c %Y "$f")')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "case.bats:1"
}

@test "bsd-stat-lint ignores a trailing comment that merely mentions the pattern" {
  local d
  d="$(_fixture trailcomment 'ls "$f"  # old: @STAT@ -f %Lp "$f" || @STAT@ -c %a "$f"')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "bsd-stat-lint still flags the pattern when a trailing comment follows it" {
  local d
  d="$(_fixture codeandcomment 'm=$(@STAT@ -f %Lp "$f" || @STAT@ -c %a "$f")  # why')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
}

@test "bsd-stat-lint allows the GNU-first order (the fallback really runs on macOS)" {
  local d
  d="$(_fixture gnufirst 'm="$(@STAT@ -c %a "$f" 2>/dev/null || @STAT@ -f %Lp "$f")"')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "bsd-stat-lint allows the OSTYPE-switched helper form" {
  local d
  d="$(_fixture ostype 'if [[ "$OSTYPE" == darwin* ]]; then @STAT@ -f %Lp "$1"; else @STAT@ -c %a "$1"; fi')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "bsd-stat-lint skips full-line comments that document the pattern" {
  local d
  d="$(_fixture comment '# do not write: @STAT@ -f %Lp "$f" || @STAT@ -c %a "$f"')"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "bsd-stat-lint scans .bash helpers too" {
  local d="$BATS_TEST_TMPDIR/bashfile"
  mkdir -p "$d"
  printf '%s\n' 'x() { @STAT@ -f %m "$1" || @STAT@ -c %Y "$1"; }' | sed "s/@STAT@/stat/g" >"$d/h.bash"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "h.bash:1"
}

@test "bsd-stat-lint refuses to pass on an empty tests dir" {
  local d="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$d"
  CAST_LINT_TESTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "scanned 0 files"
}

@test "bsd-stat-lint passes on the real tests/ tree (no override)" {
  run bash "$LINT_SCRIPT"
  assert_success
  assert_output --partial "OK"
}
