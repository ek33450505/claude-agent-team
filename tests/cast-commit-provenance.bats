#!/usr/bin/env bats
# tests/cast-commit-provenance.bats — D5 provenance substrate tests
# Covers: record/check roundtrip, missing-sha exit 1, disallowed DB path, idempotent
# double-record, SHA format guard (invalid hex rejected), column storage.
# Isolation: temp HOME + temp CAST_DB_PATH per test (setup_temp_home helpers).
# Note: all fixture SHAs must match ^[0-9a-fA-F]{7,64}$ (SHA format guard).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-commit-provenance.py"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"

  export TEST_DB="$HOME/.claude/test-provenance-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Provision the schema (so commit_provenance table exists)
  bash "$DB_INIT" --db "$TEST_DB" >/dev/null 2>&1
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# record-then-check roundtrip (happy path)
# ---------------------------------------------------------------------------

@test "cast-commit-provenance: record then check roundtrip succeeds" {
  local sha="abc1234def5678"  # valid hex, 14 chars

  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" record "$sha"
  assert_success
  assert_output --partial '"recorded"'
  assert_output --partial "$sha"

  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" check "$sha"
  assert_success
  assert_output '{"found": true}'
}

# ---------------------------------------------------------------------------
# check on unknown SHA exits 1 with {"found": false}
# ---------------------------------------------------------------------------

@test "cast-commit-provenance: check on missing sha exits 1 with found=false" {
  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" check "deadbeef0000000"
  assert_failure
  assert_output '{"found": false}'
}

# ---------------------------------------------------------------------------
# record with disallowed DB path emits valid JSON error and exits 1
# ---------------------------------------------------------------------------

@test "cast-commit-provenance: disallowed DB path emits JSON error and exits 1" {
  # /dev/null is outside the cast_db allowed-path prefixes → triggers ValueError
  run env CAST_DB_PATH="/dev/null" python3 "$SCRIPT" record "aaa1111"
  assert_failure
  # stdout must be a JSON object containing an "error" key
  assert_output --partial '"error"'
}

# ---------------------------------------------------------------------------
# idempotent double-record (second record is silently ignored)
# ---------------------------------------------------------------------------

@test "cast-commit-provenance: double-record is idempotent" {
  local sha="dead1234beef56"  # valid hex, 14 chars

  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" record "$sha"
  assert_success

  # second record should also succeed (INSERT OR IGNORE = no error)
  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" record "$sha"
  assert_success
  assert_output --partial '"recorded"'

  # still only one row in the DB
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM commit_provenance WHERE sha='$sha';"
  assert_output "1"
}

# ---------------------------------------------------------------------------
# SHA format guard — invalid values rejected before any DB operation
# ---------------------------------------------------------------------------

@test "cast-commit-provenance: record rejects non-hex sha" {
  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" record "not-a-sha!!"
  assert_failure
  assert_output '{"error": "invalid sha format"}'
}

@test "cast-commit-provenance: check rejects non-hex sha" {
  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" check "bad sha here"
  assert_failure
  assert_output '{"error": "invalid sha format"}'
}

@test "cast-commit-provenance: record rejects sha shorter than 7 chars" {
  run env CAST_DB_PATH="$TEST_DB" python3 "$SCRIPT" record "abc123"
  assert_failure
  assert_output '{"error": "invalid sha format"}'
}

# ---------------------------------------------------------------------------
# commit_provenance table exists in canonical DB (verified via db-init)
# ---------------------------------------------------------------------------

@test "cast-db-init creates commit_provenance table" {
  run sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='commit_provenance';"
  assert_success
  assert_output "1"
}

# ---------------------------------------------------------------------------
# record stores expected columns
# ---------------------------------------------------------------------------

@test "cast-commit-provenance: record stores correct columns" {
  local sha="cc001234abcdef"  # valid hex, 14 chars

  run env CAST_DB_PATH="$TEST_DB" CLAUDE_SESSION_ID="testsession42" python3 "$SCRIPT" record "$sha"
  assert_success

  run sqlite3 "$TEST_DB" "SELECT session_id, agent FROM commit_provenance WHERE sha='$sha';"
  assert_output "testsession42|commit"
}
