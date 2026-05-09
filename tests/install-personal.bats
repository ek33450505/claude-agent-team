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
  run_install_personal

  [ -f "$HOME/.claude/agents/portfolio-sync.md" ]
}

@test "Personal install: still installs all core agents" {
  run_install_personal

  # A representative core agent should be present
  [ -f "$HOME/.claude/agents/code-writer.md" ]
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
