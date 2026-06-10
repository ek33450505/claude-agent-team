#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATION_FILE="$REPO_DIR/scripts/migrations/018_routines.sql"
CAST_BIN="$REPO_DIR/bin/cast"
RUNNER="$REPO_DIR/scripts/cast-routine-runner.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/logs"

  export TEST_DB="$BATS_TEST_TMPDIR/test-routines-greenfield-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------

@test "email-triage.yaml passes validate and is enabled by default" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/email-triage.yaml"
  assert_success
  assert_output --partial "OK: email-triage"

  run grep -E '^enabled: true' "$REPO_DIR/routines/email-triage.yaml"
  assert_success
}

@test "release-celebration.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/release-celebration.yaml"
  assert_success
  assert_output --partial "OK: release-celebration"
}

@test "release-celebration runner --dry-run with missing required arg exits non-zero" {
  local routines_dir="$REPO_DIR/routines"

  run env CAST_ROUTINES_DIR="$routines_dir" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    CAST_ROUTINE_SKIP_MCP_CHECK=1 \
    bash "$RUNNER" release-celebration --dry-run

  assert_failure
  assert_output --partial "required"
}
