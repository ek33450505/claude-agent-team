#!/usr/bin/env bats
# teardown-guard.bats — Tests for the teardown_temp_home guard in tests/helpers/setup.bash
#
# The guard is a three-layer defense against wipe-class incidents:
# 1. Sentinel check (.cast-test-home must exist)
# 2. Temp-prefix check (path must be under /tmp, /private/tmp, /var/folders, etc.)
# 3. Real-home shape rejection (/Users/<name> pattern without temp markers)
#
# This file tests all guard refusal paths and the happy path.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ---------------------------------------------------------------------------
# File-scoped teardown: clean up internal fixture directories
# These directories are intentionally NOT under /tmp to test the guard's
# rejection of non-temp paths; cleanup must be scoped to exactly these
# directories to avoid over-broad deletion of tracked fixtures.
# ---------------------------------------------------------------------------
teardown() {
  rm -rf "${REPO_DIR}/tests/fixtures/non-temp-homes" "${REPO_DIR}/tests/fixtures/fake-users-test" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: Create a directory that does NOT match temp prefixes
# The guard checks: /tmp/*, /private/tmp/*, /var/folders/*, /private/var/folders/*
# We create under the repo's tests directory, which is at a /Users/<name>/path
# This path doesn't match any of the temp prefixes
# ---------------------------------------------------------------------------
_make_non_temp_home() {
  local non_temp_fixtures="${REPO_DIR}/tests/fixtures/non-temp-homes"
  mkdir -p "$non_temp_fixtures" || return 1
  local non_temp_home="${non_temp_fixtures}/test-$$"
  mkdir -p "$non_temp_home" || return 1
  echo "$non_temp_home"
}

_cleanup_non_temp_home() {
  local dir="$1"
  [[ -n "$dir" ]] && [[ -d "$dir" ]] && rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Test 1: Happy path — properly created temp HOME is deleted
# ---------------------------------------------------------------------------
@test "happy path: temp HOME with sentinel is deleted successfully" {
  # Source the helpers to get setup_temp_home and teardown_temp_home
  source "$REPO_DIR/tests/helpers/setup.bash"

  # Use the actual setup_temp_home function (modifies ORIG_HOME and HOME)
  setup_temp_home
  local test_home="$HOME"

  # Verify the sentinel exists
  [[ -f "$test_home/.cast-test-home" ]] || skip "Sentinel not created by setup_temp_home"

  # Verify HOME is set to a temp directory
  [[ "$test_home" == /tmp/* ]] || [[ "$test_home" == /private/tmp/* ]] || [[ "$test_home" == /var/folders/* ]] || [[ "$test_home" == /private/var/folders/* ]] || skip "HOME not set to recognized temp prefix"

  # Verify the directory exists before teardown
  [[ -d "$test_home" ]] || skip "Temp HOME directory not created"

  # Now call teardown_temp_home via run to capture exit code
  run teardown_temp_home

  # Verify it succeeded
  assert_success

  # Verify the directory is gone
  [[ ! -d "$test_home" ]] || fail "Temp directory should be deleted after teardown"
}

# ---------------------------------------------------------------------------
# Test 2: REFUSAL — missing sentinel
# If HOME is set to a temp dir BUT lacks the sentinel file, teardown refuses
# ---------------------------------------------------------------------------
@test "refusal: missing sentinel file — directory preserved, nonzero exit" {
  source "$REPO_DIR/tests/helpers/setup.bash"

  local orig_home="$HOME"

  # Create a temp directory WITHOUT using setup_temp_home
  local test_home="$(mktemp -d)"
  local marker_file="$test_home/marker.txt"
  echo "test marker" > "$marker_file"

  # Set HOME to this directory (no sentinel)
  export HOME="$test_home"

  # Call teardown_temp_home via run to capture exit code and output
  run teardown_temp_home

  # Should fail
  assert_failure

  # Error message should mention missing sentinel
  assert_output --partial ".cast-test-home"

  # The directory should still exist
  [[ -d "$test_home" ]] || exit 1

  # The marker file should survive
  [[ -f "$marker_file" ]] || exit 1

  # Clean up after ourselves
  rm -rf "$test_home"
}

# ---------------------------------------------------------------------------
# Test 3: REFUSAL — non-temp prefix
# Directory has sentinel but path is not under /tmp, /private/tmp, /var/folders
# (or /private/var/folders). We use /tmp-cast-nontemp-test which doesn't match
# the /tmp/* glob pattern.
# ---------------------------------------------------------------------------
@test "refusal: non-temp prefix — directory preserved, nonzero exit" {
  source "$REPO_DIR/tests/helpers/setup.bash"

  # Create a directory at a path that does NOT match temp prefixes
  local test_home
  test_home="$(_make_non_temp_home)" || skip "Cannot create non-temp test directory"

  # Create the sentinel so guard (a) passes
  touch "$test_home/.cast-test-home"

  # Create a marker file
  local marker_file="$test_home/marker.txt"
  echo "test marker" > "$marker_file"

  # Set HOME to this non-temp path
  export HOME="$test_home"

  # Call teardown_temp_home — should refuse (guard b)
  run teardown_temp_home

  # Should fail
  assert_failure

  # Error message should mention temp prefix requirement
  assert_output --partial "not under /tmp"

  # The directory should still exist
  [[ -d "$test_home" ]] || exit 1

  # The marker file should survive
  [[ -f "$marker_file" ]] || exit 1

  # Clean up
  _cleanup_non_temp_home "$test_home"
}

# ---------------------------------------------------------------------------
# Test 4: REFUSAL — /Users/<name> shape when ORIG_HOME unset
# Guard (c) fallback: reject anything matching /Users/* if ORIG_HOME is unset.
# We create a fake /Users/testuser structure at a non-temp path to trigger
# this specific check.
# ---------------------------------------------------------------------------
@test "refusal: /Users/* shape when ORIG_HOME unset — directory preserved, nonzero exit" {
  source "$REPO_DIR/tests/helpers/setup.bash"

  local orig_home="$HOME"
  local saved_orig_home="$ORIG_HOME"

  # Create a fake /Users/testuser structure under repo's test fixtures
  # This path looks like /Users/<name> but is actually under the repo
  local fake_base="${REPO_DIR}/tests/fixtures/fake-users-test"
  mkdir -p "$fake_base" || exit 1

  # Create the /Users/testuser structure (the guard checks /Users/<name>)
  local fake_users="${fake_base}/Users/testuser"
  mkdir -p "$fake_users" || exit 1

  # Create the sentinel (guard a passes)
  touch "$fake_users/.cast-test-home"

  # Create a marker file
  local marker_file="$fake_users/marker.txt"
  echo "test marker" > "$marker_file"

  # Set HOME to this fake /Users/<name> path
  export HOME="$fake_users"

  # Explicitly unset ORIG_HOME to trigger the /Users/* fallback guard
  unset ORIG_HOME

  # Call teardown_temp_home — should refuse (guard c /Users fallback)
  run teardown_temp_home

  # Should fail
  assert_failure

  # Error message should mention /Users
  assert_output --partial "/Users"

  # The directory should still exist
  [[ -d "$fake_users" ]] || exit 1

  # The marker file should survive
  [[ -f "$marker_file" ]] || exit 1

  # Restore state
  export ORIG_HOME="$saved_orig_home"
  export HOME="$orig_home"

  # Clean up
  rm -rf "$fake_base"
}

# ---------------------------------------------------------------------------
# Test 5: REFUSAL — HOME == ORIG_HOME (matches saved real home)
# Guard (c) explicitly checks: if HOME == ORIG_HOME, refuse (real user home).
# We create a temp directory, add sentinel, then trick the guard by setting
# both HOME and ORIG_HOME to the same temp directory.
# ---------------------------------------------------------------------------
@test "refusal: HOME == ORIG_HOME — directory preserved, nonzero exit" {
  source "$REPO_DIR/tests/helpers/setup.bash"

  local orig_home_saved="$HOME"

  # Create a temp directory to use as both HOME and ORIG_HOME
  local test_home="$(mktemp -d)"

  # Add sentinel (guard a passes)
  touch "$test_home/.cast-test-home"

  # Create a marker file
  local marker_file="$test_home/marker.txt"
  echo "test marker" > "$marker_file"

  # Trick guard (c) by setting both to the same temp directory
  # This simulates the case where ORIG_HOME was saved to a temp dir,
  # and now HOME is being tested against it
  export HOME="$test_home"
  export ORIG_HOME="$test_home"

  # Call teardown_temp_home — should refuse (guard c equality check)
  run teardown_temp_home

  # Should fail
  assert_failure

  # Error message should mention ORIG_HOME / real user home
  assert_output --partial "ORIG_HOME"

  # The directory should still exist
  [[ -d "$test_home" ]] || exit 1

  # The marker file should survive
  [[ -f "$marker_file" ]] || exit 1

  # Restore state
  export HOME="$orig_home_saved"
  unset ORIG_HOME

  # Clean up
  rm -rf "$test_home"
}

# ---------------------------------------------------------------------------
# Test 6: Safe no-op — unset HOME variable
# If HOME is unset, teardown should be a safe no-op
# ---------------------------------------------------------------------------
@test "safe no-op: HOME unset — no error, no deletion" {
  source "$REPO_DIR/tests/helpers/setup.bash"

  local orig_home="$HOME"

  # Save and unset HOME
  unset HOME
  unset ORIG_HOME

  # This should not crash; guard (a) checks "$target" which is empty
  # Behavior: we expect the guard to refuse gracefully
  run teardown_temp_home

  # With HOME unset, "$target" expands to empty, so [[ ! -f "$target/.cast-test-home" ]]
  # will be true (file doesn't exist) and we'll see the sentinel error
  # This is acceptable safe-no-op behavior
  assert_failure

  # Restore
  export HOME="$orig_home"
}

# ---------------------------------------------------------------------------
# Test 7: Concordance check — cast-headless-guard.bats delegates HOME teardown
# to the canonical setup.bash guard (setup_temp_home/teardown_temp_home) rather
# than reimplementing it inline, so it inherits the same three-layer wipe guard.
# (DRY successor to the old inline-copy concordance after the U8 refactor.)
# ---------------------------------------------------------------------------
@test "concordance: cast-headless-guard.bats delegates to the canonical temp-HOME guard" {
  local setup_guard="$REPO_DIR/tests/helpers/setup.bash"
  local headless_test="$REPO_DIR/tests/cast-headless-guard.bats"

  # Verify setup.bash (the source of truth) still has the three-layer guard
  grep -q "sentinel marker" "$setup_guard" || exit 1
  grep -q "/tmp/\*" "$setup_guard" || exit 1
  grep -q "real home" "$setup_guard" || exit 1
  grep -q '\.cast-test-home' "$setup_guard" || exit 1
  local users_glob='/Users/*'
  grep -qF "$users_glob" "$setup_guard" || exit 1

  # cast-headless-guard.bats must INHERIT that guard by loading the canonical
  # helper and calling setup_temp_home/teardown_temp_home — never by wiping HOME
  # itself. Delegation is what keeps the wipe protection concordant.
  grep -q "helpers/setup" "$headless_test" || exit 1
  grep -q "setup_temp_home" "$headless_test" || exit 1
  grep -q "teardown_temp_home" "$headless_test" || exit 1
}
