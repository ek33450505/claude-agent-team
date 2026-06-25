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
  [ "$status" -eq 0 ]
  [[ "$output" =~ "rules drift: main-session rules in sync" ]]
  [[ ! "$output" =~ "differ from the freshly-installed CAST baseline" ]]
}

@test "rules drift: divergent rules/ file reports WARN + reconcile hint" {
  printf 'new repo content\n' > "${HOME}/.claude/rules-core/working-conventions.md"
  printf 'stale local content\n' > "${HOME}/.claude/rules/working-conventions.md"

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "rules drift:" ]]
  [[ "$output" =~ "working-conventions.md" ]]
  [[ "$output" =~ "differ from the freshly-installed CAST baseline" ]]
  [[ "$output" =~ "do NOT blind-overwrite" ]]
}

@test "rules drift: file missing from rules/ is reported as (missing)" {
  printf 'baseline only\n' > "${HOME}/.claude/rules-core/shell.md"

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "shell.md(missing)" ]]
}

@test "rules drift: personal rules/ files without a baseline counterpart are not flagged" {
  printf 'identical\n' > "${HOME}/.claude/rules-core/agents.md"
  printf 'identical\n' > "${HOME}/.claude/rules/agents.md"
  printf 'personal\n' > "${HOME}/.claude/rules/work-projects.md"
  printf 'backup\n' > "${HOME}/.claude/rules/working-conventions.md.pre-u3.bak"

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "rules drift: main-session rules in sync" ]]
  [[ ! "$output" =~ "work-projects.md" ]]
}

@test "rules drift: empty baseline dir reports INFO skip" {
  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no CAST rules-core baseline found" ]]
}
