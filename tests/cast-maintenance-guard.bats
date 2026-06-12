#!/usr/bin/env bats
# tests/cast-maintenance-guard.bats — Integration tests for cleanup_stale_swarm_dirs()
# in scripts/cast-maintenance.sh.
#
# These tests SOURCE the real cast-maintenance.sh (source guard fires, skipping
# the main body) and call cleanup_stale_swarm_dirs() directly with
# CAST_MAINT_SWARM_TMP_ROOT pointed at a mktemp fixture root.
#
# Coverage:
#   1. Stale cast-swarm-* dir (backdated via touch -t) is removed
#   2. Fresh cast-swarm-* dir (current mtime) survives (-mtime +3 semantics)
#   3. Function returns 0 under set -euo pipefail (launchd regression)
#   4. Refusal: lib-level test confirming the || log tolerance path works
#      (direct cast_safe_rm call since engineering a refusal through the function's
#       find -type d is contrived — symlinks aren't matched by -type d)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Isolate HOME so cast-maintenance.sh sets CAST_DIR to a temp path
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  # Source the real maintenance script — source guard stops before main execution
  # shellcheck disable=SC1090
  source "$REPO_DIR/scripts/cast-maintenance.sh"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. Stale dir removed — mtime older than 3 days → find -mtime +3 matches → deleted
# ---------------------------------------------------------------------------
@test "cleanup_stale_swarm_dirs removes stale cast-swarm-* dir (mtime > 3 days)" {
  local scan_root stale_dir
  scan_root="$BATS_TEST_TMPDIR/fake-tmp-$$"
  mkdir -p "$scan_root"

  stale_dir="${scan_root}/cast-swarm-stale-$$"
  mkdir "$stale_dir"
  touch "$stale_dir/marker"

  # Backdate the directory mtime to 4 days ago so find -mtime +3 matches it
  touch -t "$(date -v -4d '+%Y%m%d%H%M')" "$stale_dir"

  CAST_MAINT_SWARM_TMP_ROOT="$scan_root" cleanup_stale_swarm_dirs

  [ ! -d "$stale_dir" ]
}

# ---------------------------------------------------------------------------
# 2. Fresh dir survives — current mtime does NOT match find -mtime +3
# ---------------------------------------------------------------------------
@test "cleanup_stale_swarm_dirs leaves fresh cast-swarm-* dir untouched (mtime ≤ 3 days)" {
  local scan_root fresh_dir
  scan_root="$BATS_TEST_TMPDIR/fake-tmp-fresh-$$"
  mkdir -p "$scan_root"

  fresh_dir="${scan_root}/cast-swarm-fresh-$$"
  mkdir "$fresh_dir"
  touch "$fresh_dir/marker"
  # mtime is now (default) — should NOT match -mtime +3

  CAST_MAINT_SWARM_TMP_ROOT="$scan_root" cleanup_stale_swarm_dirs

  [ -d "$fresh_dir" ]
}

# ---------------------------------------------------------------------------
# 3. Launchd regression — function returns 0 under set -euo pipefail
#    A stale dir is cleaned successfully; the function must not abort.
# ---------------------------------------------------------------------------
@test "cleanup_stale_swarm_dirs returns 0 under set -euo pipefail (launchd regression)" {
  local scan_root stale_dir
  scan_root="$BATS_TEST_TMPDIR/fake-tmp-launchd-$$"
  mkdir -p "$scan_root"

  stale_dir="${scan_root}/cast-swarm-launchd-$$"
  mkdir "$stale_dir"
  touch -t "$(date -v -4d '+%Y%m%d%H%M')" "$stale_dir"

  # Run inside an explicit strict-mode subshell; non-zero exit would fail the test
  (
    set -euo pipefail
    CAST_MAINT_SWARM_TMP_ROOT="$scan_root" cleanup_stale_swarm_dirs
  )

  [ ! -d "$stale_dir" ]
}

# ---------------------------------------------------------------------------
# 4. Refusal tolerance — cast_safe_rm refused path is logged, not fatal.
#
#    Honest caveat: engineering a refusal THROUGH the function's find -type d
#    is contrived (find -type d skips symlinks, the only cheap escape mechanism).
#    This test therefore exercises the lib-level refusal path directly via
#    cast_safe_rm, then confirms that the || log pattern in cleanup_stale_swarm_dirs
#    mirrors that tolerance (the function's while-loop body: cast_safe_rm ... || log).
# ---------------------------------------------------------------------------
@test "cast_safe_rm refusal is non-fatal — || log pattern works (lib-level)" {
  local outside_dir
  outside_dir="$BATS_TEST_TMPDIR/outside-radius-$$"
  mkdir "$outside_dir"
  touch "$outside_dir/canary"

  # Source the guard lib (already loaded via cast-maintenance.sh source in setup)
  cast_declare_blast_radius "/private/tmp/cast-swarm-" "/tmp/cast-swarm-"

  # Replicate the function's || log pattern — refusal must not propagate as error
  local result=0
  cast_safe_rm "$outside_dir" 2>/dev/null || result=$?
  [ "$result" -ne 0 ]            # refusal happened
  [ -f "$outside_dir/canary" ]   # target survived

  # Confirm the || tolerance: simulating the function body with set -e active
  (
    set -euo pipefail
    cast_safe_rm "$outside_dir" 2>/dev/null || true   # mirrors: ... || log "WARN..."
  )
  # Still alive here → tolerance confirmed
  [ -f "$outside_dir/canary" ]
}
