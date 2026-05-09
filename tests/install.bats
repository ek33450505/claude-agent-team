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

# Helper: run install.sh non-interactively (v3 has no menu).
# CAST_INSTALL_FORCE=1 bypasses the dirty-tree guard so tests can run in any working-tree state.
run_install() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" 2>&1
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

@test "Install: installs all core agents (no personal overlay)" {
  run_install

  local count
  count=$(ls -1 "$HOME/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  # portfolio-sync.md is personal-only; core install has 29 agents
  [ "$count" -eq 29 ]
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

@test "Install: migrations/ directory and SQL files are copied to ~/.claude/scripts/migrations/" {
  run_install

  [ -d "$HOME/.claude/scripts/migrations" ]
  # At least one .sql file must exist after install
  local sql_count
  sql_count=$(ls -1 "$HOME/.claude/scripts/migrations/"*.sql 2>/dev/null | wc -l | tr -d ' ')
  [ "$sql_count" -gt 0 ]
  # Verify the known migration file is present
  [ -f "$HOME/.claude/scripts/migrations/009_cast_framework_fixes.sql" ]
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

@test "Dirty-tree guard: exits 1 with dirty scripts/ directory" {
  # Use a temp git repo so the guard fires based on a controlled dirty state,
  # without polluting the real working tree.
  # core.hooksPath=/dev/null prevents CAST pre-commit hooks from firing in the fixture.
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  cp -R "$REPO_DIR/." "$tmp_repo/"
  git -C "$tmp_repo" -c core.hooksPath=/dev/null init -q
  git -C "$tmp_repo" add -A
  git -C "$tmp_repo" -c user.email="test@test.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "init"

  # Now dirty the tree by modifying a tracked file
  echo "# test change" >> "$tmp_repo/scripts/gen-stats.sh"
  git -C "$tmp_repo" add scripts/gen-stats.sh

  # Run install.sh from the temp repo — should exit 1 due to dirty tree
  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 1 ]

  # Verify error message mentions "uncommitted changes"
  [[ "$output" =~ "uncommitted changes" ]]

  rm -rf "$tmp_repo"
}

@test "Dirty-tree guard: allows install.sh to proceed with clean tree" {
  # Use a temp git repo with a clean tree — guard should not fire.
  # core.hooksPath=/dev/null prevents CAST pre-commit hooks from firing in the fixture.
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  cp -R "$REPO_DIR/." "$tmp_repo/"
  git -C "$tmp_repo" -c core.hooksPath=/dev/null init -q
  git -C "$tmp_repo" add -A
  git -C "$tmp_repo" -c user.email="test@test.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "init"

  # Tree is clean — install.sh should exit 0 (guard passes through)
  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 0 ]

  rm -rf "$tmp_repo"
}

@test "Dirty-tree guard: CAST_INSTALL_FORCE=1 bypasses guard with dirty tree" {
  # Use a temp git repo and make it dirty.
  # core.hooksPath=/dev/null prevents CAST pre-commit hooks from firing in the fixture.
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  cp -R "$REPO_DIR/." "$tmp_repo/"
  git -C "$tmp_repo" -c core.hooksPath=/dev/null init -q
  git -C "$tmp_repo" add -A
  git -C "$tmp_repo" -c user.email="test@test.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "init"
  echo "# force test" >> "$tmp_repo/scripts/gen-stats.sh"
  git -C "$tmp_repo" add scripts/gen-stats.sh

  # With CAST_INSTALL_FORCE=1, install.sh should succeed despite dirty tree
  run env CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -eq 0 ]

  rm -rf "$tmp_repo"
}
