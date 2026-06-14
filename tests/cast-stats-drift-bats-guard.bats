#!/usr/bin/env bats
# cast-stats-drift-bats-guard.bats — regression for the false-BLOCKED root cause.
#
# Root cause (CAST v8 A5): a test-runner dispatch surfaced a "BLOCKED" verdict that
# was NOT a real code failure — it was stats drift (cast-stats.json out of sync)
# leaking into the suite as a test failure.  scripts/gen-cast-stats.sh carries a
# BATS guard (lines ~13-23) that SKIPS (echoes a marker and exits 0) whenever it is
# run inside a BATS context (BATS_TEST_NAME / BATS_TEST_FILENAME / BATS_TMPDIR set).
# This guard exists precisely so stats drift can NEVER masquerade as a suite failure.
#
# These tests pin that kernel: prove gen-cast-stats.sh --check (and bare write mode)
# exits 0 + prints the "BATS context detected — skipping" marker inside a BATS context,
# EVEN when cast-stats.json is stale/drifted — and prove (control) that with the guard
# disabled the script does real work instead of cleanly skipping.
#
# NOTE: no existing test asserts the guard's SKIP behavior.  tests/cast-stats.bats
# deliberately `env -u`s the BATS vars to DISABLE the guard (it tests derivation), and
# tests/pre-push-stats-drift.bats uses a non-guarded stub.  Neither covers this path.
#
# Isolation: setup_temp_home (HARD RULE) — fixtures live under the temp HOME.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN_STATS_SH="$REPO_DIR/scripts/gen-cast-stats.sh"
STATS_LIB_SH="$REPO_DIR/scripts/cast-stats-lib.sh"

# Marker substring (avoid matching the em-dash in the full "detected — skipping" string).
SKIP_MARKER="BATS context detected"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

  # Build an isolated fixture "repo" whose committed cast-stats.json is DRIFTED.
  # Copy the REAL script + lib so the guard logic under test is the real one;
  # the script resolves REPO_ROOT to this fixture via its own BASH_SOURCE.
  FIXTURE="$HOME/fixture-repo"
  mkdir -p "$FIXTURE/scripts"
  cp "$GEN_STATS_SH" "$FIXTURE/scripts/gen-cast-stats.sh"
  cp "$STATS_LIB_SH" "$FIXTURE/scripts/cast-stats-lib.sh"
  cp "$REPO_DIR/VERSION" "$FIXTURE/VERSION"
  FIXTURE_GEN="$FIXTURE/scripts/gen-cast-stats.sh"

  # Deliberately drifted/stale committed stats — values that match nothing real.
  DRIFTED_JSON='{"version":"0.0.0-DRIFTED","agents":1,"tests":1,"tables":1,"commands":1,"skills":1,"packages":1,"updated":"1970-01-01"}'
  printf '%s\n' "$DRIFTED_JSON" > "$FIXTURE/cast-stats.json"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. Kernel: real script --check inside a BATS context skips (exit 0 + marker)
# ---------------------------------------------------------------------------

@test "real gen-cast-stats.sh --check skips with marker inside a BATS context" {
  # BATS_TEST_NAME / BATS_TEST_FILENAME / BATS_TMPDIR are set by bats itself here,
  # so the guard must fire — no env manipulation needed.
  run bash "$GEN_STATS_SH" --check
  assert_success
  assert_output --partial "$SKIP_MARKER"
}

# ---------------------------------------------------------------------------
# 2. Drift suppression: --check skips even when cast-stats.json is drifted
# ---------------------------------------------------------------------------

@test "--check exits 0 + marker even when committed cast-stats.json is drifted" {
  run bash "$FIXTURE_GEN" --check
  assert_success
  assert_output --partial "$SKIP_MARKER"
  # The drift was never even compared — proving stats drift cannot surface here.
  refute_output --partial "DRIFT DETECTED"
}

# ---------------------------------------------------------------------------
# 3. Control: with the guard disabled, the script does NOT cleanly skip
# ---------------------------------------------------------------------------

@test "control: --check with BATS vars unset does real work (no skip, non-zero on drift)" {
  # Unset the BATS context vars so the guard does NOT fire. The fixture is not a
  # git repo, so derivations fail their plausibility floor — the script exits
  # non-zero WITHOUT printing the skip marker. This proves the exit-0 in tests
  # 1-2 is attributable to the BATS guard, not an unconditional skip.
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    bash "$FIXTURE_GEN" --check
  assert_failure
  refute_output --partial "$SKIP_MARKER"
}

# ---------------------------------------------------------------------------
# 4. Write mode is also suppressed (guard covers bare invocation, not just --check)
# ---------------------------------------------------------------------------

@test "bare write mode is suppressed inside a BATS context (drifted file untouched)" {
  run bash "$FIXTURE_GEN"
  assert_success
  assert_output --partial "$SKIP_MARKER"
  # The guard exits before writing, so the drifted committed file must be unchanged
  # (never overwritten with inflated in-BATS counts).
  run cat "$FIXTURE/cast-stats.json"
  assert_output --partial "0.0.0-DRIFTED"
}
