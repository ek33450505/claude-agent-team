#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COUNT_SCRIPT="$REPO_DIR/scripts/cast-count-planned-tests.sh"

setup() {
  # Temp dir for fixture files (not touching real home)
  export FIXTURE_DIR="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

# ---------------------------------------------------------------------------
# Test: correct @test count on a known fixture file
# ---------------------------------------------------------------------------

@test "cast-count-planned-tests.sh: counts @test lines at start of line" {
  local fixture="$FIXTURE_DIR/sample.bats"
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '' \
    'load '"'"'test_helper'"'"'' \
    '' \
    '@test "first test" {' \
    '  echo "test 1"' \
    '}' \
    '' \
    '@test "second test" {' \
    '  echo "test 2"' \
    '}' \
    '' \
    '@test "third test" {' \
    '  echo "test 3"' \
    '}' \
    > "$fixture"

  run bash "$COUNT_SCRIPT" "$fixture"
  assert_success
  [ "$output" -eq 3 ]
}

# ---------------------------------------------------------------------------
# Test: @test inside comments should not be counted
# ---------------------------------------------------------------------------

@test "cast-count-planned-tests.sh: ignores @test in comments" {
  local fixture="$FIXTURE_DIR/with_comments.bats"
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '' \
    '# This is a comment that mentions @test inside the comment' \
    '# but @test should not be counted here' \
    '' \
    '@test "real test 1" {' \
    '  echo "test 1"' \
    '}' \
    '' \
    '# @test "fake test in comment" {' \
    '#   this should not count' \
    '# }' \
    '' \
    '@test "real test 2" {' \
    '  echo "test 2"' \
    '}' \
    > "$fixture"

  run bash "$COUNT_SCRIPT" "$fixture"
  assert_success
  [ "$output" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Test: graceful 0 (not crash) on missing/unreadable file
# ---------------------------------------------------------------------------

@test "cast-count-planned-tests.sh: returns 0 for missing file without crashing" {
  local missing="$FIXTURE_DIR/nonexistent.bats"

  run bash "$COUNT_SCRIPT" "$missing"
  assert_success
  [ "$output" -eq 0 ]
}

@test "cast-count-planned-tests.sh: returns 0 for unreadable file" {
  local unreadable="$FIXTURE_DIR/unreadable.bats"
  touch "$unreadable"
  chmod 000 "$unreadable"

  run bash "$COUNT_SCRIPT" "$unreadable"
  assert_success
  [ "$output" -eq 0 ]

  # Cleanup: restore permissions so teardown can delete
  chmod 644 "$unreadable"
}

# ---------------------------------------------------------------------------
# Test: no-args case should return 0
# ---------------------------------------------------------------------------

@test "cast-count-planned-tests.sh: no-args returns 0" {
  run bash "$COUNT_SCRIPT"
  assert_success
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test: multiple files aggregate correctly
# ---------------------------------------------------------------------------

@test "cast-count-planned-tests.sh: aggregates counts across multiple files" {
  local file1="$FIXTURE_DIR/file1.bats"
  local file2="$FIXTURE_DIR/file2.bats"

  printf '%s\n' \
    '@test "test 1" { true; }' \
    '@test "test 2" { true; }' \
    > "$file1"

  printf '%s\n' \
    '@test "test 3" { true; }' \
    '@test "test 4" { true; }' \
    '@test "test 5" { true; }' \
    > "$file2"

  run bash "$COUNT_SCRIPT" "$file1" "$file2"
  assert_success
  [ "$output" -eq 5 ]
}

# ---------------------------------------------------------------------------
# Test: handles indented @test (should not count)
# ---------------------------------------------------------------------------

@test "cast-count-planned-tests.sh: ignores indented @test lines" {
  local fixture="$FIXTURE_DIR/indented.bats"
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '' \
    '@test "real test" {' \
    '  # This @test inside a function should not count' \
    '  echo "test"' \
    '}' \
    '' \
    '  @test "indented test" {' \
    '    # This is indented, so should not count' \
    '    true' \
    '  }' \
    > "$fixture"

  run bash "$COUNT_SCRIPT" "$fixture"
  assert_success
  [ "$output" -eq 1 ]
}
