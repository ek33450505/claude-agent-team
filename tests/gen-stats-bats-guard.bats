#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN_STATS="$REPO_DIR/scripts/gen-stats.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export ORIG_BATS_TEST_NAME="${BATS_TEST_NAME:-}"
  export ORIG_BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
  export ORIG_BATS_TMPDIR="${BATS_TMPDIR:-}"

  export HOME="$(mktemp -d)"

  # Create a fake README with sentinel values
  FAKE_README="$HOME/README.md"
  cat > "$FAKE_README" <<'EOF'
# CAST

## Statistics

<!-- CAST_AGENT_COUNT -->999<!-- /CAST_AGENT_COUNT -->
<!-- CAST_COMMAND_COUNT -->888<!-- /CAST_COMMAND_COUNT -->
<!-- CAST_SKILL_COUNT -->777<!-- /CAST_SKILL_COUNT -->
<!-- CAST_TEST_COUNT -->666<!-- /CAST_TEST_COUNT -->
<!-- CAST_ROUTE_COUNT -->555<!-- /CAST_ROUTE_COUNT -->
EOF

  export TEST_README="$FAKE_README"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  # Restore original BATS env vars
  if [[ -n "$ORIG_BATS_TEST_NAME" ]]; then
    export BATS_TEST_NAME="$ORIG_BATS_TEST_NAME"
  else
    unset BATS_TEST_NAME
  fi
  if [[ -n "$ORIG_BATS_TEST_FILENAME" ]]; then
    export BATS_TEST_FILENAME="$ORIG_BATS_TEST_FILENAME"
  else
    unset BATS_TEST_FILENAME
  fi
  if [[ -n "$ORIG_BATS_TMPDIR" ]]; then
    export BATS_TMPDIR="$ORIG_BATS_TMPDIR"
  else
    unset BATS_TMPDIR
  fi
}

# ---------------------------------------------------------------------------
# Test 1: BATS_TEST_NAME guard — gen-stats exits 0 and does NOT modify README
# ---------------------------------------------------------------------------

@test "gen-stats exits 0 and does NOT modify README when BATS_TEST_NAME is set" {
  # Set BATS_TEST_NAME to simulate being inside a BATS test
  export BATS_TEST_NAME="some-test"

  # Read original content
  ORIGINAL=$(cat "$TEST_README")

  # Run gen-stats with the fake README
  run bash "$GEN_STATS" "$TEST_README"
  assert_success
  assert_output --partial "BATS context detected"

  # Verify README was NOT modified
  MODIFIED=$(cat "$TEST_README")
  [[ "$ORIGINAL" == "$MODIFIED" ]]
}

# ---------------------------------------------------------------------------
# Test 2: BATS_TEST_FILENAME guard — gen-stats exits 0 and does NOT modify README
# ---------------------------------------------------------------------------

@test "gen-stats exits 0 and does NOT modify README when BATS_TEST_FILENAME is set" {
  # Set BATS_TEST_FILENAME to simulate being inside a BATS test
  export BATS_TEST_FILENAME="/path/to/tests/some.bats"

  # Unset other BATS vars to isolate this test
  unset BATS_TEST_NAME
  unset BATS_TMPDIR

  # Read original content
  ORIGINAL=$(cat "$TEST_README")

  # Run gen-stats with the fake README
  run bash "$GEN_STATS" "$TEST_README"
  assert_success
  assert_output --partial "BATS context detected"

  # Verify README was NOT modified
  MODIFIED=$(cat "$TEST_README")
  [[ "$ORIGINAL" == "$MODIFIED" ]]
}

# ---------------------------------------------------------------------------
# Test 3: BATS_TMPDIR guard — gen-stats exits 0 and does NOT modify README
# ---------------------------------------------------------------------------

@test "gen-stats exits 0 and does NOT modify README when BATS_TMPDIR is set" {
  # Set BATS_TMPDIR to simulate being inside a BATS test
  export BATS_TMPDIR="/tmp/bats-tmpdir"

  # Unset other BATS vars to isolate this test
  unset BATS_TEST_NAME
  unset BATS_TEST_FILENAME

  # Read original content
  ORIGINAL=$(cat "$TEST_README")

  # Run gen-stats with the fake README
  run bash "$GEN_STATS" "$TEST_README"
  assert_success
  assert_output --partial "BATS context detected"

  # Verify README was NOT modified
  MODIFIED=$(cat "$TEST_README")
  [[ "$ORIGINAL" == "$MODIFIED" ]]
}

# ---------------------------------------------------------------------------
# Test 4: Normal path — gen-stats DOES modify README when no BATS vars are set
# ---------------------------------------------------------------------------

@test "gen-stats DOES modify README when no BATS env vars are set" {
  # Unset all BATS env vars to test the normal, non-guarded path
  unset BATS_TEST_NAME
  unset BATS_TEST_FILENAME
  unset BATS_TMPDIR

  # Run gen-stats in a clean subshell with no BATS env vars
  # We use env -u to guarantee they're unset even if BATS sets them at this level
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    bash "$GEN_STATS" "$TEST_README"
  assert_success

  # Verify README WAS modified — the test count sentinel should have changed
  # Original value was "<!-- CAST_TEST_COUNT -->666<!-- /CAST_TEST_COUNT -->"
  # The actual count is determined by git ls-files in the repo, which should be > 0
  MODIFIED=$(cat "$TEST_README")

  # Assert that the sentinel was updated (should not be 666 anymore)
  # We check that the CAST_TEST_COUNT line no longer has 666
  ! grep -q "<!-- CAST_TEST_COUNT -->666<!-- /CAST_TEST_COUNT -->" "$TEST_README"
}
