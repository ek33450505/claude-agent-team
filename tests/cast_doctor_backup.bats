#!/usr/bin/env bats

# Tests for cast doctor backup freshness check (check #17)
# Mirrors cast-doctor-expansion.bats isolation pattern exactly:
# isolated HOME, cast.db auto-created on first access, temp CAST_BACKUP_ROOT

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Create .claude/cast/events so sqlite3 can auto-create cast.db there
  mkdir -p "${HOME}/.claude/cast/events"

  # Resolve repo directory
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/." && pwd)/.."
}

teardown() {
  teardown_temp_home
}

@test "doctor WARN when no snapshots found" {
  # Set backup root to an empty directory (no snapshots)
  export CAST_BACKUP_ROOT="$(mktemp -d)"

  run bash "$REPO_DIR/bin/cast" doctor

  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

  # Output should contain "Backups:" and the WARN marker "[!!]"
  [[ "$output" =~ "Backups:" ]]
  [[ "$output" =~ "!!" ]]

  # Cleanup temp backup root
  rm -rf "$CAST_BACKUP_ROOT"
}

@test "doctor OK when fresh snapshot exists" {
  # Create a fresh snapshot directory with today's date
  export CAST_BACKUP_ROOT="$(mktemp -d)"
  TODAY=$(date +%Y-%m-%d)
  mkdir -p "$CAST_BACKUP_ROOT/cast-snapshot-$TODAY"

  run bash "$REPO_DIR/bin/cast" doctor

  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

  # Output should contain "Backups:" and the OK marker "[ok]"
  [[ "$output" =~ "Backups:" ]]
  [[ "$output" =~ "ok" ]]

  # Cleanup temp backup root
  rm -rf "$CAST_BACKUP_ROOT"
}
