#!/usr/bin/env bats
# tests/ci-workflow-integrity.bats
# Regression tests for CI workflow configuration correctness.
# Catches missing setup steps that cause hook tests to fail with exit code 127
# on a clean CI runner (scripts not present at ~/.claude/scripts/).

bats_require_minimum_version 1.5.0

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEST_INSTALLER_YML="$REPO_DIR/.github/workflows/test-installer.yml"
BATS_CI_YML="$REPO_DIR/.github/workflows/bats-ci.yml"

# ── test-installer.yml must have runtime setup in both jobs ──────────────────

@test "test-installer.yml: bats-ubuntu job has 'Set up CAST runtime dirs' step" {
  run grep -c "Set up CAST runtime dirs" "$TEST_INSTALLER_YML"
  # File has two jobs (ubuntu + macos), each needs the step → count >= 2
  [ "$output" -ge 2 ]
}

@test "test-installer.yml: bats-ubuntu job copies scripts to ~/.claude/scripts/" {
  run grep "cp scripts/\*.sh ~/.claude/scripts/" "$TEST_INSTALLER_YML"
  assert_success
}

@test "test-installer.yml: bats-macos job copies scripts to ~/.claude/scripts/" {
  # Both jobs must have the cp step — ensure it appears at least twice
  run grep -c "cp scripts/\*.sh ~/.claude/scripts/" "$TEST_INSTALLER_YML"
  [ "$output" -ge 2 ]
}

@test "test-installer.yml: runtime setup step precedes 'Run full BATS suite' in ubuntu job" {
  # Extract line numbers for each step to confirm ordering
  setup_line=$(grep -n "Set up CAST runtime dirs" "$TEST_INSTALLER_YML" | head -1 | cut -d: -f1)
  bats_line=$(grep -n "Run full BATS suite" "$TEST_INSTALLER_YML" | head -1 | cut -d: -f1)
  [ "$setup_line" -lt "$bats_line" ]
}

@test "test-installer.yml: runtime setup step runs chmod +x on installed scripts" {
  run grep "chmod +x ~/.claude/scripts/\*.sh" "$TEST_INSTALLER_YML"
  assert_success
}

# ── bats-ci.yml parity: same pattern already present ────────────────────────

@test "bats-ci.yml: has 'Set up CAST runtime dirs' step (reference implementation)" {
  run grep "Set up CAST runtime dirs" "$BATS_CI_YML"
  assert_success
}

@test "bats-ci.yml and test-installer.yml: both use identical cp command" {
  bats_ci_cp=$(grep "cp scripts/\*.sh ~/.claude/scripts/" "$BATS_CI_YML" | head -1 | tr -d ' ')
  installer_cp=$(grep "cp scripts/\*.sh ~/.claude/scripts/" "$TEST_INSTALLER_YML" | head -1 | tr -d ' ')
  [ "$bats_ci_cp" = "$installer_cp" ]
}

# ── test-installer.yml: *.py copy present in both jobs ──────────────────────

@test "test-installer.yml: bats-ubuntu job copies *.py scripts to ~/.claude/scripts/" {
  # Must appear at least twice (once per job)
  run grep -c "cp scripts/\*.py ~/.claude/scripts/" "$TEST_INSTALLER_YML"
  [ "$output" -ge 2 ]
}

@test "test-installer.yml: bats-macos job copies *.py scripts to ~/.claude/scripts/" {
  # Confirm the py copy line appears in the macos job section
  macos_section=$(awk '/bats-macos:/,0' "$TEST_INSTALLER_YML")
  run echo "$macos_section"
  assert_output --partial "cp scripts/*.py ~/.claude/scripts/"
}

@test "test-installer.yml: *.py copy parity with bats-ci.yml" {
  run grep "cp scripts/\*.py ~/.claude/scripts/" "$BATS_CI_YML"
  assert_success
  run grep "cp scripts/\*.py ~/.claude/scripts/" "$TEST_INSTALLER_YML"
  assert_success
}
