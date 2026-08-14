#!/usr/bin/env bats
# tests/cast-log-rotate.bats — Prune-scope assertions for scripts/cast-log-rotate.sh
#
# Focus: §3b legacy-backups dir prune is an explicit ALLOWLIST, not a catch-all.
# The only verified directory writer into ~/.claude/backups/ is install.sh's
# BACKUP_DIR="$CLAUDE_DIR/backups/$(date +%Y%m%d-%H%M%S)" (install.sh's own
# prune at install.sh:764 uses the equivalent ^[0-9]{8}-[0-9]{6}$ regex), so
# `20*-*` is the sole allowlisted pattern — gated twice (find -name filter,
# then the case statement as a second safety net). Anything else (e.g. a
# stray `.claude/` config-snapshot duplicate) is left alone, unconditionally,
# regardless of age.
#
#   (a) a stale non-20*-* dir is PRESERVED (not on the allowlist)
#   (b) a fresh non-20*-* dir is NOT pruned
#   (c) $LEGACY_BACKUP_DIR itself always survives (mindepth 1 protects the root)
#   (d) prune is skipped fail-closed when cast_safe_rm/cast-guard-lib is unavailable
#   (e) an allowlisted (20*-*) stale dir IS pruned, and its path is logged
#       immediately before deletion
#   (f) a cast_safe_rm refusal is logged (not swallowed) via a stub guard lib
#
# File age is backdated via python3 os.utime (portable; avoids BSD-only date -v).
# Uses isolated temp HOME; never touches real ~/.claude or the live cast.db.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-log-rotate.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Backdate a file/dir's atime+mtime by N seconds relative to now.
_backdate() {
  local path="$1"
  local age_secs="$2"
  python3 - "$path" "$age_secs" <<'PY'
import sys, os, time
path, age = sys.argv[1], int(sys.argv[2])
t = time.time() - age
os.utime(path, (t, t))
PY
}

# Default LEGACY_BACKUP_DIR_DAYS gate is 14 days (CAST_LEGACY_BACKUP_DIR_DAYS).
_15_days=$((15 * 86400))

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  export LEGACY_BACKUP_DIR="$HOME/.claude/backups"
  mkdir -p "$LEGACY_BACKUP_DIR"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# (a) non-allowlisted stale dir is preserved
# ---------------------------------------------------------------------------

@test "log-rotate: non-allowlisted stale dir under legacy backups is preserved" {
  local stale_dir="$LEGACY_BACKUP_DIR/.claude"
  mkdir -p "$stale_dir"
  echo '{}' > "$stale_dir/cast.json"
  _backdate "$stale_dir" "$_15_days"

  run bash "$SCRIPT"
  assert_success

  [ -d "$stale_dir" ] || {
    echo "FAIL: non-allowlisted dir was pruned despite not matching the 20*-* allowlist"
    return 1
  }
}

# ---------------------------------------------------------------------------
# (b) fresh non-20*-* dir survives
# ---------------------------------------------------------------------------

@test "log-rotate: fresh non-20*-* dir under legacy backups survives" {
  local fresh_dir="$LEGACY_BACKUP_DIR/.claude"
  mkdir -p "$fresh_dir"
  echo '{}' > "$fresh_dir/cast.json"
  # mtime is 'now' — do not backdate

  run bash "$SCRIPT"
  assert_success

  [ -d "$fresh_dir" ] || {
    echo "FAIL: fresh non-20*-* dir was incorrectly pruned"
    return 1
  }
}

# ---------------------------------------------------------------------------
# (c) LEGACY_BACKUP_DIR root itself is never removed
# ---------------------------------------------------------------------------

@test "log-rotate: LEGACY_BACKUP_DIR root itself always survives" {
  local snapshot_dir="$LEGACY_BACKUP_DIR/20250101-000000"
  mkdir -p "$snapshot_dir"
  _backdate "$snapshot_dir" "$_15_days"

  run bash "$SCRIPT"
  assert_success

  [ -d "$LEGACY_BACKUP_DIR" ] || {
    echo "FAIL: LEGACY_BACKUP_DIR root was removed"
    return 1
  }
}

# ---------------------------------------------------------------------------
# (d) fail-closed when cast_safe_rm / cast-guard-lib.sh is unavailable
# ---------------------------------------------------------------------------

@test "log-rotate: prune skipped fail-closed when cast-guard-lib.sh is unavailable" {
  # Copy the script alone into an isolated dir with no cast-guard-lib.sh
  # sibling, and no ~/.claude/scripts/cast-guard-lib.sh fallback under the
  # fresh temp HOME — both source attempts must fail, leaving cast_safe_rm
  # undefined.
  #
  # Fixture MUST be an allowlisted (20*-*) dir: using a non-allowlisted name
  # here would make the test pass for the wrong reason (allowlist mismatch
  # instead of fail-closed-on-missing-guard).
  local isolated_dir="$HOME/isolated-scripts"
  mkdir -p "$isolated_dir"
  cp "$SCRIPT" "$isolated_dir/cast-log-rotate.sh"

  local snapshot_dir="$LEGACY_BACKUP_DIR/20250101-000000"
  mkdir -p "$snapshot_dir"
  _backdate "$snapshot_dir" "$_15_days"

  run bash "$isolated_dir/cast-log-rotate.sh"
  assert_success

  [ -d "$snapshot_dir" ] || {
    echo "FAIL: allowlisted dir was pruned despite cast_safe_rm being unavailable (not fail-closed)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# (e) allowlisted stale dir is pruned, and its path is logged
# ---------------------------------------------------------------------------

@test "log-rotate: allowlisted stale 20*-* dir is pruned and its path is logged" {
  local snapshot_dir="$LEGACY_BACKUP_DIR/20250101-000000"
  mkdir -p "$snapshot_dir/agents"
  _backdate "$snapshot_dir" "$_15_days"

  run bash "$SCRIPT"
  assert_success

  [ ! -d "$snapshot_dir" ] || {
    echo "FAIL: allowlisted 20*-* dir was not pruned"
    return 1
  }

  assert_output --partial "pruning stale legacy-backup dir: ${snapshot_dir}"
}

# ---------------------------------------------------------------------------
# (f) cast_safe_rm refusal is logged, not swallowed
# ---------------------------------------------------------------------------

@test "log-rotate: cast_safe_rm refusal is logged, not swallowed" {
  # Isolated copy of the script paired with a STUBBED cast-guard-lib.sh whose
  # cast_safe_rm always refuses deterministically. This isolates "is a
  # refusal surfaced in the log" from any specific real cast_safe_rm refusal
  # condition (which are all safety-critical edge cases, not something to
  # fight to trigger from a test).
  local isolated_dir="$HOME/isolated-refuse"
  mkdir -p "$isolated_dir"
  cp "$SCRIPT" "$isolated_dir/cast-log-rotate.sh"

  cat > "$isolated_dir/cast-guard-lib.sh" <<'EOF'
cast_declare_blast_radius() { :; }
cast_safe_rm() {
  echo "FATAL [cast_safe_rm]: refusing '$1' — stub refusal for test" >&2
  return 1
}
EOF

  local snapshot_dir="$LEGACY_BACKUP_DIR/20250101-000000"
  mkdir -p "$snapshot_dir"
  _backdate "$snapshot_dir" "$_15_days"

  run bash "$isolated_dir/cast-log-rotate.sh"
  assert_success

  # Stub refused the delete — dir must survive.
  [ -d "$snapshot_dir" ] || {
    echo "FAIL: dir was removed despite stub cast_safe_rm refusing"
    return 1
  }

  # The refusal must be visible in the log output, not swallowed.
  assert_output --partial "REFUSED"
  assert_output --partial "stub refusal for test"
}
