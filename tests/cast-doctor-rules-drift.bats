#!/usr/bin/env bats

# Tests for the `cast doctor` rules-drift check (master_v9 §10.15):
# detects when ~/.claude/rules/ (skip-if-exists, loaded by the main session) has diverged
# from the CAST-owned ~/.claude/rules-core/ baseline (overwritten on every install).

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "${HOME}/.claude/rules-core"
  mkdir -p "${HOME}/.claude/rules"
}

teardown() {
  teardown_temp_home
}

@test "rules drift: in-sync baseline reports OK, no drift warning" {
  printf 'identical content\n' > "${HOME}/.claude/rules-core/working-conventions.md"
  printf 'identical content\n' > "${HOME}/.claude/rules/working-conventions.md"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "rules drift: 1 baseline file(s) in sync" ]]
  [[ ! "$output" =~ "differ from the freshly-installed CAST baseline" ]]
}

@test "rules drift: divergent rules/ file reports WARN + reconcile hint" {
  printf 'new repo content\n' > "${HOME}/.claude/rules-core/working-conventions.md"
  printf 'stale local content\n' > "${HOME}/.claude/rules/working-conventions.md"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "rules drift (of 1 baseline file(s) compared)" ]]
  [[ "$output" =~ "working-conventions.md" ]]
  [[ "$output" =~ "differ from the freshly-installed CAST baseline" ]]
  [[ "$output" =~ "do NOT blind-overwrite" ]]
}

@test "rules drift: file missing from rules/ is reported as (missing)" {
  printf 'baseline only\n' > "${HOME}/.claude/rules-core/shell.md"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "shell.md(missing)" ]]
}

@test "rules drift: personal rules/ files without a baseline counterpart are not flagged" {
  printf 'identical\n' > "${HOME}/.claude/rules-core/agents.md"
  printf 'identical\n' > "${HOME}/.claude/rules/agents.md"
  printf 'personal\n' > "${HOME}/.claude/rules/work-projects.md"
  printf 'backup\n' > "${HOME}/.claude/rules/working-conventions.md.pre-u3.bak"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "rules drift: 1 baseline file(s) in sync" ]]
  [[ ! "$output" =~ "work-projects.md" ]]
}

@test "rules drift: empty baseline dir reports INFO skip" {
  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "no CAST rules-core baseline found" ]]
}

@test "rules drift: OK branch names the number of baseline files compared" {
  printf 'a\n' > "${HOME}/.claude/rules-core/agents.md"
  printf 'a\n' > "${HOME}/.claude/rules/agents.md"
  printf 'b\n' > "${HOME}/.claude/rules-core/shell.md"
  printf 'b\n' > "${HOME}/.claude/rules/shell.md"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "rules drift: 2 baseline file(s) in sync" ]]
}

@test "rules drift: WARN branch names cast rules sync as the remediation" {
  printf 'new repo content\n' > "${HOME}/.claude/rules-core/working-conventions.md"
  printf 'stale local content\n' > "${HOME}/.claude/rules/working-conventions.md"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "cast rules sync"[[:space:]]*\(report-only ]]
  [[ "$output" =~ "cast rules sync --apply" ]]
}

@test "rules drift: subset baseline makes the compared-file count visible (regression for Wave F2)" {
  # Simulates the real-world defect: rules-core/ holds only a curated subset (here: 2 files)
  # while ~/.claude/rules/ holds more files overall (here: 5). The check can only ever see
  # what's in rules-core/, so the compared count MUST reflect the small baseline (2), not the
  # larger rules/ directory (5) — proving the scope is visible in the output rather than
  # silently implying full coverage.
  printf 'a\n' > "${HOME}/.claude/rules-core/agents.md"
  printf 'a\n' > "${HOME}/.claude/rules/agents.md"
  printf 'b\n' > "${HOME}/.claude/rules-core/shell.md"
  printf 'b\n' > "${HOME}/.claude/rules/shell.md"
  printf 'c\n' > "${HOME}/.claude/rules/python.md"
  printf 'd\n' > "${HOME}/.claude/rules/tests.md"
  printf 'e\n' > "${HOME}/.claude/rules/typescript.md"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "rules drift: 2 baseline file(s) in sync" ]]
  [[ ! "$output" =~ "5 baseline file(s)" ]]
}
