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

# --- Overlay sync freshness (doctor line after check 18) ---

_overlay_stamp() {
  # $1 = hours ago -> UTC stamp (python3: BSD/GNU date flags differ)
  python3 -I -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1])*3600)))' "$1"
}

@test "doctor Overlay OK when last sync was 1h ago" {
  export CAST_BACKUP_ROOT="$(mktemp -d)"
  mkdir -p "$HOME/.claude/logs"
  printf '[%s] [info] Overlay sync complete\n' "$(_overlay_stamp 1)" > "$HOME/.claude/logs/cast-overlay-sync.log"

  run bash "$REPO_DIR/bin/cast" doctor
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  echo "$output" | grep -qF "Overlay: last sync 1h ago"
  echo "$output" | grep -F "Overlay:" | grep -qF "[ok]"
  ! echo "$output" | grep -F "Overlay:" | grep -qF "[!!]"
  rm -rf "$CAST_BACKUP_ROOT"
}

@test "doctor Overlay ignores a future-dated forged success line (WARN)" {
  export CAST_BACKUP_ROOT="$(mktemp -d)"
  mkdir -p "$HOME/.claude/logs"
  {
    printf '[%s] [info] Overlay sync complete\n' "$(_overlay_stamp 100)"
    printf '[%s] [info] Overlay sync complete\n' "$(_overlay_stamp -48)"
  } > "$HOME/.claude/logs/cast-overlay-sync.log"

  run bash "$REPO_DIR/bin/cast" doctor
  [ "$status" -eq 1 ]
  echo "$output" | grep -F "Overlay:" | grep -qF "[!!]"
  echo "$output" | grep -qF "last successful sync 100h ago"
  rm -rf "$CAST_BACKUP_ROOT"
}

@test "doctor Overlay prints control bytes in the error text as ?" {
  export CAST_BACKUP_ROOT="$(mktemp -d)"
  mkdir -p "$HOME/.claude/logs"
  printf '[%s] [error] bad\033[31m\rthing\a\n' "$(_overlay_stamp 1)" > "$HOME/.claude/logs/cast-overlay-sync.log"

  run bash "$REPO_DIR/bin/cast" doctor
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'last error: bad?[31m?thing?'
  ! printf '%s' "$output" | grep -q "$(printf '\033')"
  rm -rf "$CAST_BACKUP_ROOT"
}

@test "doctor Overlay WARN when last success is 100h old, with the newest error" {
  export CAST_BACKUP_ROOT="$(mktemp -d)"
  mkdir -p "$HOME/.claude/logs"
  {
    printf '[%s] [info] Overlay sync complete\n' "$(_overlay_stamp 100)"
    printf '[%s] [error] Failed to pull from origin\n' "$(_overlay_stamp 2)"
  } > "$HOME/.claude/logs/cast-overlay-sync.log"

  run bash "$REPO_DIR/bin/cast" doctor
  [ "$status" -eq 1 ]
  [[ "$output" =~ "!!] Overlay: last successful sync 100h ago (threshold 72h); last error: Failed to pull from origin" ]]
  rm -rf "$CAST_BACKUP_ROOT"
}

@test "doctor prints no Overlay line when the overlay log is absent" {
  export CAST_BACKUP_ROOT="$(mktemp -d)"
  run bash "$REPO_DIR/bin/cast" doctor
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ ! "$output" =~ "Overlay:" ]]
  rm -rf "$CAST_BACKUP_ROOT"
}
