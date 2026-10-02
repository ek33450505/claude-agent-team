#!/usr/bin/env bats
# cast-backup-scheduled.bats — Tests for cast-backup-scheduled.sh
#
# Covers the entry point for the daily com.cast.backup launchd job.
# All tests use setup_temp_home / teardown_temp_home to isolate operations
# from the real ~/.claude directory (HARD RULE).
#
# Coverage:
#   1. Snapshot OK + Overlay OK → exit 0; log contains both success messages
#   2. Snapshot FAILS → exit 0 (daemon style); log marks snapshot failure
#   3. Snapshot OK + Overlay FAILS → exit 0; overlay marked non-fatal in log
#   4. Overlay script missing → handled gracefully (no crash)
#   5. Real log file never touched (log stays in temp HOME)
#   6. Snapshot exit code properly captured and communicated

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-backup-scheduled.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Create .claude/scripts directory for stubs
  SCRIPTS_DIR="$HOME/.claude/scripts"
  mkdir -p "$SCRIPTS_DIR"
  LOGS_DIR="$HOME/.claude/logs"
  mkdir -p "$LOGS_DIR"

  # Override CAST_SCRIPTS_DIR to temp scripts directory
  export CAST_SCRIPTS_DIR="$SCRIPTS_DIR"
}

teardown() {
  load 'helpers/setup'
  teardown_temp_home
}

# ============================================================================
# Helper functions
# ============================================================================

create_snapshot_success_stub() {
  cat > "$SCRIPTS_DIR/cast-snapshot.py" <<'STUB'
#!/usr/bin/env python3
import sys
print("Snapshot: backing up database", file=sys.stdout)
sys.exit(0)
STUB
  chmod +x "$SCRIPTS_DIR/cast-snapshot.py"
}

create_snapshot_failure_stub() {
  cat > "$SCRIPTS_DIR/cast-snapshot.py" <<'STUB'
#!/usr/bin/env python3
import sys
print("Snapshot ERROR: cannot acquire lock", file=sys.stderr)
sys.exit(1)
STUB
  chmod +x "$SCRIPTS_DIR/cast-snapshot.py"
}

create_overlay_success_stub() {
  cat > "$SCRIPTS_DIR/cast-overlay-sync.sh" <<'STUB'
#!/usr/bin/env bash
set -u
echo "Overlay: synced to remote"
exit 0
STUB
  chmod +x "$SCRIPTS_DIR/cast-overlay-sync.sh"
}

create_overlay_failure_stub() {
  cat > "$SCRIPTS_DIR/cast-overlay-sync.sh" <<'STUB'
#!/usr/bin/env bash
set -u
echo "Overlay ERROR: gh auth failed" >&2
exit 1
STUB
  chmod +x "$SCRIPTS_DIR/cast-overlay-sync.sh"
}

# ============================================================================
# Test 1: Both snapshot and overlay succeed
# ============================================================================

@test "snapshot and overlay both succeed: exit 0" {
  create_snapshot_success_stub
  create_overlay_success_stub
  run bash "$SCRIPT"
  assert_success
}

@test "snapshot and overlay both succeed: log contains both success messages" {
  create_snapshot_success_stub
  create_overlay_success_stub
  bash "$SCRIPT"

  grep -q "Step 1: On-disk snapshot SUCCEEDED" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Step 2: Overlay push SUCCEEDED" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "SUMMARY: Snapshot succeeded. Overlay: succeeded" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 2: Snapshot fails
# ============================================================================

@test "snapshot fails: exits 0 (daemon style)" {
  create_snapshot_failure_stub
  create_overlay_success_stub
  run bash "$SCRIPT"
  assert_success
}

@test "snapshot fails: log marks snapshot failure" {
  create_snapshot_failure_stub
  create_overlay_success_stub
  bash "$SCRIPT"

  grep -q "Step 1: On-disk snapshot FAILED" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "SUMMARY: Snapshot FAILED" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 3: Snapshot succeeds, overlay fails (non-fatal)
# ============================================================================

@test "snapshot succeeds, overlay fails: exits 0 (non-fatal)" {
  create_snapshot_success_stub
  create_overlay_failure_stub
  run bash "$SCRIPT"
  assert_success
}

@test "snapshot succeeds, overlay fails: log shows both steps with overlay marked non-fatal" {
  create_snapshot_success_stub
  create_overlay_failure_stub
  bash "$SCRIPT"

  grep -q "Step 1: On-disk snapshot SUCCEEDED" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Step 2: Overlay push FAILED" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "non-fatal" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 4: Overlay script missing
# ============================================================================

@test "overlay script missing: exits 0 and logs gracefully" {
  create_snapshot_success_stub
  # Do NOT create cast-overlay-sync.sh
  run bash "$SCRIPT"
  assert_success
}

@test "overlay script missing: step 2 failure logged but non-fatal" {
  create_snapshot_success_stub
  # Do NOT create cast-overlay-sync.sh
  bash "$SCRIPT"

  grep -q "Step 1: On-disk snapshot SUCCEEDED" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Step 2.*FAILED" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "non-fatal" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 5: Log file stays in temp HOME (isolation)
# ============================================================================

@test "log file created in temp HOME, not real ~/.claude" {
  create_snapshot_success_stub
  create_overlay_success_stub

  # Note the real logs dir
  local real_log_dir="${ORIG_HOME}/.claude/logs"
  local real_log_file="$real_log_dir/cast-backup-scheduled.log"

  # Get real log mtime before (if exists)
  local real_mtime_before=""
  if [[ -f "$real_log_file" ]]; then
    real_mtime_before="$(stat -f%m "$real_log_file" 2>/dev/null || stat -c%Y "$real_log_file" 2>/dev/null)"
  fi

  # Run script in temp HOME
  bash "$SCRIPT"

  # Verify temp HOME log exists
  [[ -f "$LOGS_DIR/cast-backup-scheduled.log" ]]

  # Verify real log unchanged
  if [[ -f "$real_log_file" && -n "$real_mtime_before" ]]; then
    local real_mtime_after
    real_mtime_after="$(stat -f%m "$real_log_file" 2>/dev/null || stat -c%Y "$real_log_file" 2>/dev/null)"
    [[ "$real_mtime_before" == "$real_mtime_after" ]]
  fi
}

# ============================================================================
# Test 6: Log contains timestamps and proper structure
# ============================================================================

@test "log file contains ISO-8601 timestamps" {
  create_snapshot_success_stub
  create_overlay_success_stub
  bash "$SCRIPT"

  grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$LOGS_DIR/cast-backup-scheduled.log"
}

@test "log file contains all required status markers" {
  create_snapshot_success_stub
  create_overlay_success_stub
  bash "$SCRIPT"

  grep -q "=== Starting scheduled backup run ===" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "=== Backup run complete ===" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Step 1: Running on-disk snapshot" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Step 2: Running overlay push" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 7: Mutation test — overlay failure is non-fatal
# ============================================================================

@test "mutation: overlay failure does not prevent final summary" {
  create_snapshot_success_stub
  create_overlay_failure_stub

  bash "$SCRIPT"

  # Script must exit 0 and show a summary despite overlay failure
  [[ -f "$LOGS_DIR/cast-backup-scheduled.log" ]]
  grep -q "SUMMARY: Snapshot succeeded" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "failed/skipped (non-fatal)" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 8: Snapshot and overlay output captured in log
# ============================================================================

@test "snapshot and overlay output captured in log file" {
  cat > "$SCRIPTS_DIR/cast-snapshot.py" <<'STUB'
#!/usr/bin/env python3
import sys
print("Snapshot: output message", file=sys.stdout)
print("Snapshot: error message", file=sys.stderr)
sys.exit(0)
STUB
  chmod +x "$SCRIPTS_DIR/cast-snapshot.py"

  cat > "$SCRIPTS_DIR/cast-overlay-sync.sh" <<'STUB'
#!/usr/bin/env bash
set -u
echo "Overlay: output message"
echo "Overlay: error message" >&2
exit 0
STUB
  chmod +x "$SCRIPTS_DIR/cast-overlay-sync.sh"

  bash "$SCRIPT"

  grep -q "Snapshot: output message" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Snapshot: error message" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Overlay: output message" "$LOGS_DIR/cast-backup-scheduled.log"
  grep -q "Overlay: error message" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 9: Overlay absent AND snapshot fails
# ============================================================================

@test "snapshot fails, overlay missing: logs both failures, exits 0" {
  create_snapshot_failure_stub
  # Don't create overlay stub

  run bash "$SCRIPT"
  assert_success

  # Verify log reflects failure
  grep -q "FAILED" "$LOGS_DIR/cast-backup-scheduled.log"
}

# ============================================================================
# Test 10: Contract test — always exit 0
# ============================================================================

@test "contract: script always exits 0 regardless of step outcomes" {
  create_snapshot_failure_stub
  create_overlay_failure_stub

  run bash "$SCRIPT"
  assert_success
}
