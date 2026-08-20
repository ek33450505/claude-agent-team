load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-rules-sync.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  FIXTURE_DIR="$(mktemp -d)"
  CORE_DIR="$FIXTURE_DIR/rules-core"
  LIVE_DIR="$FIXTURE_DIR/live-rules"
  BACKUP_DIR="$FIXTURE_DIR/backups"
  mkdir -p "$CORE_DIR" "$LIVE_DIR" "$BACKUP_DIR"
  export CAST_RULES_CORE_DIR="$CORE_DIR"
  export CAST_LIVE_RULES_DIR="$LIVE_DIR"
  export CAST_RULES_SYNC_BACKUP_DIR="$BACKUP_DIR"
}

teardown() {
  chmod -R u+rwx "$FIXTURE_DIR" 2>/dev/null || true
  rm -rf "$FIXTURE_DIR"
  teardown_temp_home
}

@test "dry-run reports WOULD-UPDATE for a differing CORE file, exits 0, and does not write" {
  echo "old content" >"$LIVE_DIR/foo.md"
  echo "new content" >"$CORE_DIR/foo.md"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "WOULD-UPDATE: foo.md"

  run cat "$LIVE_DIR/foo.md"
  assert_output "old content"
}

@test "dry-run reports WOULD-CREATE for a CORE file with no live counterpart" {
  echo "brand new" >"$CORE_DIR/bar.md"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "WOULD-CREATE: bar.md"
  [[ ! -f "$LIVE_DIR/bar.md" ]]
}

@test "dry-run on identical dirs reports IN-SYNC and exits 0" {
  echo "same content" >"$CORE_DIR/baz.md"
  echo "same content" >"$LIVE_DIR/baz.md"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "IN-SYNC: baz.md"
  refute_output --partial "WOULD-UPDATE"
  refute_output --partial "WOULD-CREATE"
}

@test "--apply with CAST_RULES_SYNC_ACK updates the live file and echoes the reason" {
  echo "old content" >"$LIVE_DIR/foo.md"
  echo "new content" >"$CORE_DIR/foo.md"

  run env CAST_RULES_SYNC_ACK="test reason" bash "$SCRIPT" --apply
  assert_success
  assert_output --partial "test reason"

  run cat "$LIVE_DIR/foo.md"
  assert_output "new content"
}

@test "--apply creates a backup holding the PRE-sync live content" {
  echo "old content" >"$LIVE_DIR/foo.md"
  echo "new content" >"$CORE_DIR/foo.md"

  run env CAST_RULES_SYNC_ACK="test reason" bash "$SCRIPT" --apply
  assert_success

  backup_subdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'rules-sync-*' | head -n1)"
  [[ -n "$backup_subdir" ]]
  run cat "$backup_subdir/foo.md"
  assert_output "old content"
}

@test "--apply non-interactive with no ack refuses, names CAST_RULES_SYNC_ACK, and leaves live file unchanged" {
  echo "old content" >"$LIVE_DIR/foo.md"
  echo "new content" >"$CORE_DIR/foo.md"

  run bash "$SCRIPT" --apply
  assert_failure
  assert_output --partial "CAST_RULES_SYNC_ACK"

  run cat "$LIVE_DIR/foo.md"
  assert_output "old content"
}

@test "TEMPLATE sources are never synced, even under --apply" {
  echo "template body" >"$CORE_DIR/foo.md.template"
  echo "core body" >"$CORE_DIR/tracked.md"

  run env CAST_RULES_SYNC_ACK="test reason" bash "$SCRIPT" --apply
  assert_success

  [[ ! -f "$LIVE_DIR/foo.md" ]]
  # Content-based check (not just the expected filename) so the assertion
  # still catches a mutation that syncs the template under a different name.
  run bash -c "grep -rl 'template body' '$LIVE_DIR' || true"
  assert_output ""

  run cat "$LIVE_DIR/tracked.md"
  assert_output "core body"
}

@test "a live-only file with no repo source is never deleted or modified by --apply" {
  echo "live only content" >"$LIVE_DIR/orphan.md"
  echo "core body" >"$CORE_DIR/tracked.md"

  run env CAST_RULES_SYNC_ACK="test reason" bash "$SCRIPT" --apply
  assert_success

  run cat "$LIVE_DIR/orphan.md"
  assert_output "live only content"
}

@test "zero CORE files exits 1 with ERROR" {
  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "ERROR"
}

@test "backup failure is fail-closed: unwritable backup root aborts and leaves live file unchanged" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "running as root — chmod 500 does not block root from writing"
  fi

  echo "old content" >"$LIVE_DIR/foo.md"
  echo "new content" >"$CORE_DIR/foo.md"

  chmod 500 "$BACKUP_DIR"
  run env CAST_RULES_SYNC_ACK="test reason" bash "$SCRIPT" --apply
  chmod 700 "$BACKUP_DIR"

  assert_failure
  assert_output --partial "ERROR"

  run cat "$LIVE_DIR/foo.md"
  assert_output "old content"
}

@test "--apply with CAST_RULES_SYNC_ACK set but EMPTY refuses, and the live file is unchanged" {
  echo "old content" >"$LIVE_DIR/foo.md"
  echo "new content" >"$CORE_DIR/foo.md"

  run env CAST_RULES_SYNC_ACK="" bash "$SCRIPT" --apply
  assert_failure
  assert_output --partial "CAST_RULES_SYNC_ACK"

  run cat "$LIVE_DIR/foo.md"
  assert_output "old content"
}

@test "dry-run output includes the unified diff body, not just the word diff" {
  echo "old content" >"$LIVE_DIR/foo.md"
  echo "new content" >"$CORE_DIR/foo.md"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "-old content"
  assert_output --partial "+new content"
}

@test "--apply when everything is already in sync exits 0, prints Nothing to do, and creates no backup dir" {
  echo "same content" >"$LIVE_DIR/foo.md"
  echo "same content" >"$CORE_DIR/foo.md"

  run env CAST_RULES_SYNC_ACK="test reason" bash "$SCRIPT" --apply
  assert_success
  assert_output --partial "Nothing to do"

  backup_subdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'rules-sync-*' | head -n1)"
  [[ -z "$backup_subdir" ]]
}

@test "unknown flag exits 2 with an error on stderr" {
  run bash "$SCRIPT" --bogus-flag
  assert_equal "$status" 2
  assert_output --partial "unknown flag"
}

@test "--help exits 0 and prints the usage block" {
  run bash "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: cast-rules-sync.sh"
  assert_output --partial "--apply"
}

@test "per-file cp failure during backup is fail-closed: unreadable source aborts and leaves live files unchanged" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "running as root — chmod 000 does not block root from reading"
  fi

  echo "old content a" >"$LIVE_DIR/aaa.md"
  echo "new content a" >"$CORE_DIR/aaa.md"
  echo "old content b" >"$LIVE_DIR/bbb.md"
  echo "new content b" >"$CORE_DIR/bbb.md"

  chmod 000 "$LIVE_DIR/bbb.md"
  run env CAST_RULES_SYNC_ACK="test reason" bash "$SCRIPT" --apply
  chmod 644 "$LIVE_DIR/bbb.md"

  assert_failure
  assert_output --partial "ERROR"
  assert_output --partial "back up"

  run cat "$LIVE_DIR/aaa.md"
  assert_output "old content a"
  run cat "$LIVE_DIR/bbb.md"
  assert_output "old content b"
}

@test "REGRESSION: installed copy with no git repo and no known checkout hard-refuses on a stale rules-core rather than silently adopting it" {
  installed_scripts="$HOME/.claude/scripts"
  installed_core="$HOME/.claude/rules-core"
  mkdir -p "$installed_scripts" "$installed_core"
  cp "$SCRIPT" "$installed_scripts/cast-rules-sync.sh"
  # Mirrors the REAL deployed shape: install.sh:261 copies working-conventions.md
  # (among others) into ~/.claude/rules-core/ at install time, so this exact
  # file legitimately EXISTS at the install destination on every installed
  # machine. A predicate that only checks for working-conventions.md cannot
  # tell this apart from a real repo checkout — that was the bug.
  echo "STALE" >"$installed_core/working-conventions.md"
  echo "STALE" >"$installed_core/shell.md"
  # No $HOME/Projects/personal/claude-agent-team checkout in this fake HOME —
  # the fallback-2 candidate must not exist either.

  unset CAST_RULES_CORE_DIR

  nogit_dir="$HOME/nogit"
  mkdir -p "$nogit_dir"
  cd "$nogit_dir"

  run bash "$installed_scripts/cast-rules-sync.sh"
  assert_failure
  assert_output --partial "cannot resolve repo root"
  # Never got far enough to propose a sync from the stale install snapshot.
  refute_output --partial "WOULD-UPDATE"
  refute_output --partial "WOULD-CREATE"
}

@test "REGRESSION: --apply on the installed copy with no git repo never writes over hand-tuned live rules" {
  installed_scripts="$HOME/.claude/scripts"
  installed_core="$HOME/.claude/rules-core"
  installed_live="$HOME/.claude/rules"
  mkdir -p "$installed_scripts" "$installed_core" "$installed_live"
  cp "$SCRIPT" "$installed_scripts/cast-rules-sync.sh"
  echo "STALE" >"$installed_core/working-conventions.md"
  echo "STALE" >"$installed_core/shell.md"
  echo "HAND-TUNED" >"$installed_live/shell.md"

  unset CAST_RULES_CORE_DIR
  export CAST_LIVE_RULES_DIR="$installed_live"

  nogit_dir="$HOME/nogit2"
  mkdir -p "$nogit_dir"
  cd "$nogit_dir"

  run env CAST_RULES_SYNC_ACK="probe" CAST_LIVE_RULES_DIR="$installed_live" bash "$installed_scripts/cast-rules-sync.sh" --apply
  assert_failure
  assert_output --partial "cannot resolve repo root"

  # The property that matters: nothing was written, not just a nonzero exit.
  run cat "$installed_live/shell.md"
  assert_output "HAND-TUNED"
}
