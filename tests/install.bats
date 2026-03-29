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

# Helper: run install.sh non-interactively (v3 has no menu)
run_install() {
  bash "$REPO_DIR/install.sh" 2>&1
  return $?
}

# =============================================================================
# Install (v3 — flat, non-interactive)
# =============================================================================

@test "Install: creates ~/.claude directory structure" {
  run_install

  [ -d "$HOME/.claude/agents" ]
  [ -d "$HOME/.claude/commands" ]
  [ -d "$HOME/.claude/skills" ]
  [ -d "$HOME/.claude/rules" ]
  [ -d "$HOME/.claude/plans" ]
  [ -d "$HOME/.claude/briefings" ]
  [ -d "$HOME/.claude/agent-memory-local" ]
}

@test "Install: installs all 15 agents" {
  run_install

  local count
  count=$(ls -1 "$HOME/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 15 ]
}

@test "Install: installs all 7 skills" {
  run_install

  [ -d "$HOME/.claude/skills/briefing-writer" ]
  [ -d "$HOME/.claude/skills/careful-mode" ]
  [ -d "$HOME/.claude/skills/freeze-mode" ]
  [ -d "$HOME/.claude/skills/git-activity" ]
  [ -d "$HOME/.claude/skills/merge" ]
  [ -d "$HOME/.claude/skills/plan" ]
  [ -d "$HOME/.claude/skills/wizard" ]
}

@test "Install: .template extension stripped from rules" {
  run_install

  [ -f "$HOME/.claude/rules/stack-context.md" ]
  [ ! -f "$HOME/.claude/rules/stack-context.md.template" ]
}

@test "Install: scripts are executable" {
  run_install

  [ -x "$HOME/.claude/scripts/tidy.sh" ]
}

@test "Backup: existing agents dir is backed up before overwrite" {
  # First install
  run_install

  # Second install — should trigger backup
  run_install

  # A backup directory should exist containing an agents/ subdirectory
  local backup_base="$HOME/.claude/backups"
  [ -d "$backup_base" ]

  # Find the backup dir (there may be two if both runs created one, we need at least one with agents/)
  local found=false
  for dir in "$backup_base"/*/; do
    if [ -d "${dir}agents" ]; then
      found=true
      break
    fi
  done
  [ "$found" = true ]
}

@test "Rules: existing rule file is not overwritten" {
  # First install
  run_install

  # Modify a rule file
  echo "CUSTOM_MARKER" >> "$HOME/.claude/rules/working-conventions.md"

  # Second install
  run_install

  # The custom marker should still be there (file was not overwritten)
  grep -q "CUSTOM_MARKER" "$HOME/.claude/rules/working-conventions.md"
}
