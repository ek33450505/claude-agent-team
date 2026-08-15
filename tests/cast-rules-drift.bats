#!/usr/bin/env bats

# Tests for scripts/cast-rules-drift.sh — detects drift between the repo's
# rules-core/ and the live ~/.claude/rules/ (read-only; never syncs).
# Every test drives fixtures through CAST_RULES_CORE_DIR / CAST_LIVE_RULES_DIR
# so the real ~/.claude/rules is never touched; temp HOME isolation is kept
# as a second layer since the script reads $HOME by default when unset.

setup() {
  load 'helpers/setup'
  setup_temp_home
  cd "$(git rev-parse --show-toplevel)" || exit 1
  RC="${HOME}/rc-fixture"
  LIVE="${HOME}/live-fixture"
  mkdir -p "$RC" "$LIVE"
}

teardown() {
  teardown_temp_home
}

@test "identical core file: exit 0, reported OK" {
  printf 'shared content\n' > "${RC}/agents.md"
  printf 'shared content\n' > "${LIVE}/agents.md"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ "[OK]" ]]
  [[ "$output" =~ "agents.md" ]]
  [[ "$output" =~ "matches" ]]
  [[ "$output" =~ "Result: no drift" ]]
}

@test "differing core file: exit 1, output names the file" {
  printf 'repo content\n' > "${RC}/agents.md"
  printf 'stale live content\n' > "${LIVE}/agents.md"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 1 ]
  [[ "$output" =~ "[DRIFT]" ]]
  [[ "$output" =~ "agents.md" ]]
  [[ "$output" =~ "content differs" ]]
  [[ "$output" =~ "reinstall will NOT fix this" ]]
}

@test "template with differing live content: exit 0, content not compared" {
  printf 'template placeholder\n' > "${RC}/project-catalog.md.template"
  printf 'totally different user content\n' > "${LIVE}/project-catalog.md"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ "[OK]" ]]
  [[ "$output" =~ "project-catalog.md.template" ]]
  [[ "$output" =~ "present" ]]
  [[ "$output" =~ "Result: no drift" ]]
}

@test "template with missing live counterpart: exit 1" {
  printf 'template placeholder\n' > "${RC}/project-catalog.md.template"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 1 ]
  [[ "$output" =~ "[DRIFT]" ]]
  [[ "$output" =~ "project-catalog.md.template" ]]
  [[ "$output" =~ "MISSING in" ]]
}

@test "live-only allowlisted file (work-projects.md): exit 0, reported as INFO" {
  printf 'core content\n' > "${RC}/agents.md"
  printf 'core content\n' > "${LIVE}/agents.md"
  printf 'personal work rules\n' > "${LIVE}/work-projects.md"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ "[INFO]" ]]
  [[ "$output" =~ "work-projects.md" ]]
  [[ "$output" =~ "allowlisted" ]]
  [[ "$output" =~ "Result: no drift" ]]
}

@test "live-only unlisted file: reported as drift, exit 1" {
  printf 'core content\n' > "${RC}/agents.md"
  printf 'core content\n' > "${LIVE}/agents.md"
  printf 'mystery content\n' > "${LIVE}/mystery-rule.md"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 1 ]
  [[ "$output" =~ "[DRIFT]" ]]
  [[ "$output" =~ "mystery-rule.md" ]]
  [[ "$output" =~ "NOT on the allowlist" ]]
}

@test "core file missing from live: exit 1" {
  printf 'repo-only content\n' > "${RC}/scripts.md"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 1 ]
  [[ "$output" =~ "[DRIFT]" ]]
  [[ "$output" =~ "scripts.md" ]]
  [[ "$output" =~ "MISSING-LIVE" ]]
}

@test "empty rules-core dir: exit 1 with scanned-0 message" {
  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 1 ]
  [[ "$output" =~ "scanned 0 files" ]]
}

@test "drift report line is not split by a stray pipefail newline" {
  printf 'repo content\n' > "${RC}/agents.md"
  printf 'stale live content\n' > "${LIVE}/agents.md"

  run env CAST_RULES_CORE_DIR="$RC" CAST_LIVE_RULES_DIR="$LIVE" bash scripts/cast-rules-drift.sh
  [ "$status" -eq 1 ]
  drift_line="$(echo "$output" | grep '^\[DRIFT\]')"
  [[ "$drift_line" =~ "diff lines)" ]]
}
