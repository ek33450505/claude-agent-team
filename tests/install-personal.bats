#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

# Helper: run install.sh without --personal
# CAST_INSTALL_FORCE=1 bypasses the dirty-tree guard so tests can run in any working-tree state.
run_install_core() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" 2>&1
  return $?
}

# Helper: run install.sh with --personal
run_install_personal() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" --personal 2>&1
  return $?
}

# =============================================================================
# Core-only install (no --personal flag)
# =============================================================================

@test "Core install: does not install portfolio-sync.md" {
  run_install_core

  [ ! -f "$HOME/.claude/agents/portfolio-sync.md" ]
}

@test "Core install: installs rules from rules-core/" {
  run_install_core

  # working-conventions.md is a core rule — must be present
  [ -f "$HOME/.claude/rules/working-conventions.md" ]
}

@test "Core install: does not install personal rules that are not in rules-core/" {
  run_install_core

  # rules-personal/ is empty in the repo by default; no personal files should appear
  # Verify portfolio-sync is absent from agents (core check)
  [ ! -f "$HOME/.claude/agents/portfolio-sync.md" ]
}

# =============================================================================
# Personal overlay install (with --personal flag)
# =============================================================================

@test "Personal install: installs portfolio-sync.md" {
  skip "portfolio-sync archived in v7 Phase 4.5; agents/personal/ is empty. Unskip when a new personal-overlay agent is added."
  run_install_personal

  [ -f "$HOME/.claude/agents/portfolio-sync.md" ]
}

@test "Personal install: still installs all core agents" {
  run_install_personal

  # A representative core agent should be present
  [ -f "$HOME/.claude/agents/frontend-writer.md" ]
  [ -f "$HOME/.claude/agents/commit.md" ]
}

@test "Personal install: still installs core rules" {
  run_install_personal

  [ -f "$HOME/.claude/rules/working-conventions.md" ]
  [ -f "$HOME/.claude/rules/shell.md" ]
}

# =============================================================================
# Idempotency: personal files survive subsequent core-only install
# =============================================================================

@test "Idempotency: personal agent not removed by subsequent core install" {
  skip "portfolio-sync archived in v7 Phase 4.5; agents/personal/ is empty. Unskip when a new personal-overlay agent is added."
  # First run with --personal to install portfolio-sync.md
  run_install_personal

  [ -f "$HOME/.claude/agents/portfolio-sync.md" ]

  # Second run without --personal — must NOT remove personal file
  run_install_core

  [ -f "$HOME/.claude/agents/portfolio-sync.md" ]
}

@test "Idempotency: core rules not overwritten by subsequent core install" {
  # First install
  run_install_core

  # Modify a rule file to simulate user customization
  echo "CUSTOM_MARKER_PERSONAL" >> "$HOME/.claude/rules/working-conventions.md"

  # Second core install — skip-if-exists logic should preserve the custom marker
  run_install_core

  grep -q "CUSTOM_MARKER_PERSONAL" "$HOME/.claude/rules/working-conventions.md"
}

# =============================================================================
# managed-settings-personal overlay
# =============================================================================

@test "Personal install: copies managed-settings-personal/12-otel.json (if present in repo)" {
  if [[ ! -f "$REPO_DIR/managed-settings-personal/12-otel.json" ]]; then
    skip "managed-settings-personal/12-otel.json not present in repo"
  fi

  run_install_personal

  [ -f "$HOME/.claude/managed-settings.d/12-otel.json" ] || {
    echo "FAIL: 12-otel.json not installed into managed-settings.d/ by --personal" >&2
    return 1
  }
}

@test "Core install: does NOT install managed-settings-personal/ files" {
  run_install_core

  # 12-otel.json must NOT appear from a plain install
  [ ! -f "$HOME/.claude/managed-settings.d/12-otel.json" ] || {
    echo "FAIL: 12-otel.json was installed by a core (non-personal) install — consent violation" >&2
    return 1
  }
}

@test "Personal install: managed-settings-personal files are skip-if-exists (non-destructive)" {
  if [[ ! -f "$REPO_DIR/managed-settings-personal/12-otel.json" ]]; then
    skip "managed-settings-personal/12-otel.json not present in repo"
  fi

  # First --personal install
  run_install_personal

  # Simulate user customization of the file
  local dest="$HOME/.claude/managed-settings.d/12-otel.json"
  printf 'CUSTOM_MARKER\n' >> "$dest"

  # Second --personal install — must NOT overwrite (skip-if-exists)
  run_install_personal

  grep -q "CUSTOM_MARKER" "$dest" || {
    echo "FAIL: 12-otel.json was overwritten on reinstall — expected skip-if-exists" >&2
    return 1
  }
}
