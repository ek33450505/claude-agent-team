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

run_install_personal() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" --personal 2>&1
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
  # merge converted to skill + 7 agents retired + email-drafter merged into docs in v7 Phase 4.5;
  # +2 agents added Phase 4.5.4 (eval-writer, pr-reviewer); portfolio-sync was personal/ (archived);
  # merge.md moved from archive back to core (v7.3 PR lifecycle chain); core install has 23 agents
  [ "$count" -eq 23 ]
}

@test "Install: installs core skills (spot-check)" {
  run_install

  [ -d "$HOME/.claude/skills/briefing-writer" ]
  [ -d "$HOME/.claude/skills/careful-mode" ]
  [ -d "$HOME/.claude/skills/freeze-mode" ]
  [ -d "$HOME/.claude/skills/git-activity" ]
  [ -d "$HOME/.claude/skills/merge" ]
  [ -d "$HOME/.claude/skills/plan" ]
  [ -d "$HOME/.claude/skills/wizard" ]
}

@test "Install: user-data skill (swarm) is preserved on reinstall" {
  # First install — stub is written because destination does not exist yet
  run_install
  [ -f "$HOME/.claude/skills/swarm/SKILL.md" ]

  # Simulate user populating the skill with custom content
  echo "USER_SWARM_SENTINEL" > "$HOME/.claude/skills/swarm/SKILL.md"

  # Second install — user content must NOT be overwritten
  run_install
  grep -q "USER_SWARM_SENTINEL" "$HOME/.claude/skills/swarm/SKILL.md"
}

@test "Install: default install (no --personal) does NOT install project-catalog" {
  # project-catalog is now personal-gated; core install must not write it
  run_install
  [ ! -e "$HOME/.claude/skills/project-catalog/SKILL.md" ]
}

@test "Install: --personal install writes project-catalog stub on fresh HOME" {
  # No pre-existing skill; --personal install must copy the stub
  run_install_personal
  [ -f "$HOME/.claude/skills/project-catalog/SKILL.md" ]
  # The installed file must not be empty
  [ -s "$HOME/.claude/skills/project-catalog/SKILL.md" ]
}

@test "Install: --personal install preserves user-populated project-catalog on reinstall" {
  # First personal install — stub is written
  run_install_personal
  [ -f "$HOME/.claude/skills/project-catalog/SKILL.md" ]

  # Simulate user populating the catalog with real project data
  echo "MY_REAL_PROJECT_CATALOG_SENTINEL" > "$HOME/.claude/skills/project-catalog/SKILL.md"

  # Second personal install — user content must NOT be overwritten (skip-if-exists)
  run_install_personal
  grep -q "MY_REAL_PROJECT_CATALOG_SENTINEL" "$HOME/.claude/skills/project-catalog/SKILL.md"
}

@test "Install: dead skills (compact-discipline, thinking-budget) are absent after install" {
  # Pre-create them in the temp HOME to verify the rm cleanup removes them
  mkdir -p "$HOME/.claude/skills/compact-discipline"
  echo "stale" > "$HOME/.claude/skills/compact-discipline/SKILL.md"
  mkdir -p "$HOME/.claude/skills/thinking-budget"
  echo "stale" > "$HOME/.claude/skills/thinking-budget/SKILL.md"

  run_install

  [ ! -e "$HOME/.claude/skills/compact-discipline" ]
  [ ! -e "$HOME/.claude/skills/thinking-budget" ]
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
  # Discard any inherited .git (e.g., CI's detached pull/N/merge state) so init creates a fresh repo.
  rm -rf "$tmp_repo/.git"
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
  # Discard any inherited .git (e.g., CI's detached pull/N/merge state) so init creates a fresh repo.
  rm -rf "$tmp_repo/.git"
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
  # Discard any inherited .git (e.g., CI's detached pull/N/merge state) so init creates a fresh repo.
  rm -rf "$tmp_repo/.git"
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

@test "Backup retention: keeps only the 5 most recent install snapshots" {
  # Pre-populate 7 fake timestamp dirs in the isolated temp HOME backups dir
  local backup_base="$HOME/.claude/backups"
  mkdir -p "$backup_base"

  # Create 7 dirs with valid YYYYMMDD-HHMMSS names (8+6 digits)
  local dirs=()
  for ts in 20260601-120001 20260602-120002 20260603-120003 20260604-120004 \
            20260605-120005 20260606-120006 20260607-120007; do
    local d="$backup_base/$ts"
    mkdir -p "$d"
    dirs+=("$d")
  done

  # Also create a cast-db file and an ad-hoc snapshot — these must survive
  touch "$backup_base/cast-db-2026-06-01.db"
  mkdir -p "$backup_base/_phase1-backup-manual"

  # Run install (creates one more timestamped dir, total snapshot dirs becomes 8)
  run_install

  # Count surviving timestamp-pattern dirs (macOS-safe: no -regextype)
  local count=0
  while IFS= read -r -d '' d; do
    local dname
    dname="$(basename "$d")"
    if [[ "$dname" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
      count=$(( count + 1 ))
    fi
  done < <(find "$backup_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  # Must keep exactly 5 (keep-last-N=5)
  [ "$count" -eq 5 ]

  # cast-db file must survive
  [ -f "$backup_base/cast-db-2026-06-01.db" ]

  # Ad-hoc snapshot must survive
  [ -d "$backup_base/_phase1-backup-manual" ]
}
