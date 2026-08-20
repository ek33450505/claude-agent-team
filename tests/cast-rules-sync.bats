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
