#!/usr/bin/env bats
#
# CAST v10 Wave F2 — rules-drift WARN coverage.
# install.sh keeps rules-core skip-if-exists (never overwrite); this suite
# covers the added report-only drift WARN that fires when a live core rule
# (rules-core/*.md) differs from the repo source. *.md.template files must
# NEVER be counted as drift (they are user-specialized by design).

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

run_install_core() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" 2>&1
  return $?
}

@test "drift WARN: identical live rule produces no warning, Skipped line still prints" {
  run_install_core
  [ -f "$HOME/.claude/rules/working-conventions.md" ]

  # Second install: dest is now byte-identical to repo source -> no drift.
  run run_install_core
  [ "$status" -eq 0 ]
  assert_output --partial "Skipped (exists): working-conventions.md"
  refute_output --partial "core rule file(s) have drifted"
}

@test "drift WARN: differing live rule fires warning naming the file and the remedy" {
  run_install_core
  echo "# local customization" >> "$HOME/.claude/rules/shell.md"

  run run_install_core
  [ "$status" -eq 0 ]
  assert_output --partial "1 core rule file(s) have drifted"
  assert_output --partial "shell.md"
  assert_output --partial "cast rules sync"
}

@test "drift WARN: a drifted .md.template counterpart is NOT counted" {
  run_install_core
  # project-catalog.md.template installs as project-catalog.md (dest drops .template)
  local dest="$HOME/.claude/rules/project-catalog.md"
  if [ ! -f "$dest" ]; then
    skip "rules-core/project-catalog.md.template not present in this checkout"
  fi
  echo "# user-specialized content" >> "$dest"

  run run_install_core
  [ "$status" -eq 0 ]
  refute_output --partial "core rule file(s) have drifted"
}

@test "drift WARN: multiple drifted files are all counted and listed" {
  run_install_core
  echo "# drift 1" >> "$HOME/.claude/rules/shell.md"
  echo "# drift 2" >> "$HOME/.claude/rules/python.md"

  run run_install_core
  [ "$status" -eq 0 ]
  assert_output --partial "2 core rule file(s) have drifted"
  assert_output --partial "shell.md"
  assert_output --partial "python.md"
}

@test "drift WARN: install.sh still exits 0 when drift is present" {
  run_install_core
  echo "# drift" >> "$HOME/.claude/rules/shell.md"

  run run_install_core
  [ "$status" -eq 0 ]
}
