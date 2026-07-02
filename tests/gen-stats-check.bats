#!/usr/bin/env bats
# tests/gen-stats-check.bats — coverage for gen-stats.sh --check mode
#
# Strategy: use a temp fixture README populated by mutation mode (BATS vars unset)
# then run --check (which bypasses the BATS guard) to verify read-only comparison.
# Never points at the real README.md.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN_STATS="$REPO_DIR/scripts/gen-stats.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  FIXTURE_DIR="$(mktemp -d)"
  FIXTURE_README="$FIXTURE_DIR/README.md"

  # Create fixture with dummy sentinel tokens and badge URLs.
  # Mutation mode (invoked with BATS vars unset) will populate them with real values.
  printf '# Test README\n\n' > "$FIXTURE_README"
  printf '![Agents](https://img.shields.io/badge/agents-0-green)\n' >> "$FIXTURE_README"
  printf '![Tests](https://img.shields.io/badge/tests-0-brightgreen)\n' >> "$FIXTURE_README"
  printf '![Version](https://img.shields.io/badge/version-0.0.0-blue)\n\n' >> "$FIXTURE_README"
  printf '<!-- CAST_AGENT_COUNT -->0<!-- /CAST_AGENT_COUNT -->\n' >> "$FIXTURE_README"
  printf '<!-- CAST_COMMAND_COUNT -->0<!-- /CAST_COMMAND_COUNT -->\n' >> "$FIXTURE_README"
  printf '<!-- CAST_SKILL_COUNT -->0<!-- /CAST_SKILL_COUNT -->\n' >> "$FIXTURE_README"
  printf '<!-- CAST_TEST_COUNT -->0<!-- /CAST_TEST_COUNT -->\n' >> "$FIXTURE_README"
  printf '<!-- CAST_TEST_FILE_COUNT -->0<!-- /CAST_TEST_FILE_COUNT -->\n' >> "$FIXTURE_README"
  printf '<!-- CAST_ROUTE_COUNT -->0<!-- /CAST_ROUTE_COUNT -->\n' >> "$FIXTURE_README"
  printf '<!-- CAST_DB_TABLE_COUNT -->0<!-- /CAST_DB_TABLE_COUNT -->\n' >> "$FIXTURE_README"
}

teardown() {
  teardown_temp_home
  rm -rf "$FIXTURE_DIR"
}

# ---------------------------------------------------------------------------
# Helper: populate fixture README with real values via mutation mode
# ---------------------------------------------------------------------------
_populate_fixture() {
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    bash "$GEN_STATS" "$FIXTURE_README"
  # caller asserts success if needed
}

# ---------------------------------------------------------------------------
# Test (a): in-sync fixture README → exit 0
# ---------------------------------------------------------------------------

@test "--check exits 0 when README sentinels and badges are in sync" {
  _populate_fixture
  assert_success

  # --check is read-only and bypasses the BATS guard — should pass
  run bash "$GEN_STATS" "$FIXTURE_README" --check
  assert_success
  assert_output --partial "in sync"
}

# ---------------------------------------------------------------------------
# Test (b): planted sentinel drift → exit 1 and names the token
# ---------------------------------------------------------------------------

@test "--check exits 1 and names the drifted sentinel token" {
  _populate_fixture
  assert_success

  # Plant drift in CAST_TEST_COUNT
  sed -i.bak \
    's|<!-- CAST_TEST_COUNT -->[0-9]*<!-- /CAST_TEST_COUNT -->|<!-- CAST_TEST_COUNT -->9999<!-- /CAST_TEST_COUNT -->|' \
    "$FIXTURE_README"
  rm -f "$FIXTURE_README.bak"

  run bash "$GEN_STATS" "$FIXTURE_README" --check
  assert_failure
  assert_output --partial "CAST_TEST_COUNT"
  assert_output --partial "expected="
  assert_output --partial "found=9999"
}

# ---------------------------------------------------------------------------
# Test (c): planted badge drift → exit 1
# ---------------------------------------------------------------------------

@test "--check exits 1 when badge URL count is wrong" {
  _populate_fixture
  assert_success

  # Plant drift in the tests badge count
  sed -i.bak \
    's|/badge/tests-[0-9]*-brightgreen|/badge/tests-9999-brightgreen|' \
    "$FIXTURE_README"
  rm -f "$FIXTURE_README.bak"

  run bash "$GEN_STATS" "$FIXTURE_README" --check
  assert_failure
  assert_output --partial "badge tests"
  assert_output --partial "9999"
}

# ---------------------------------------------------------------------------
# Test (d): --check leaves the fixture file byte-identical (no writes, no .bak)
# ---------------------------------------------------------------------------

@test "--check leaves fixture file byte-identical and leaves no .bak behind" {
  _populate_fixture
  assert_success

  BEFORE=$(shasum "$FIXTURE_README" | awk '{print $1}')

  run bash "$GEN_STATS" "$FIXTURE_README" --check
  assert_success

  AFTER=$(shasum "$FIXTURE_README" | awk '{print $1}')

  [[ "$BEFORE" == "$AFTER" ]] || {
    echo "--check modified the fixture file" >&2
    return 1
  }

  # No .bak files left behind
  [ ! -f "${FIXTURE_README}.bak" ] || {
    echo "--check left a .bak file behind" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test (e): mutation mode still refuses under BATS env vars (guard unchanged)
# ---------------------------------------------------------------------------

@test "mutation mode (no --check) is still blocked under BATS env vars" {
  ORIGINAL="$(cat "$FIXTURE_README")"

  # Do NOT unset BATS vars — mutation mode should see them and refuse
  run bash "$GEN_STATS" "$FIXTURE_README"
  assert_success
  assert_output --partial "BATS context detected"

  MODIFIED="$(cat "$FIXTURE_README")"
  [[ "$ORIGINAL" == "$MODIFIED" ]] || {
    echo "mutation mode modified the fixture despite BATS guard" >&2
    return 1
  }
}
