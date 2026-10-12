#!/usr/bin/env bats
# tests/agents/effort-frontmatter.bats — Task 2.5 / Task 4.x: effort field policy
# Policy (Phase 4 → Phase 3a): effort field is only meaningful for opus-tier agents.
# Every non-opus agent (haiku AND sonnet) MUST NOT have an effort: line in frontmatter.
# Opus exemption: migration-reviewer.md (model: opus) is the sole agent permitted to
# retain an effort: field (currently effort: high).
#
# Phase 3a (2026-06-09): effort: low was removed from all haiku agents.
# bash-specialist was moved haiku→sonnet; api-contract was moved sonnet→haiku.
# Both remain effort-free under the uniform non-opus rule.

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

AGENTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../agents/core" && pwd)"
PERSONAL_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../agents/personal" 2>/dev/null && pwd)" || PERSONAL_DIR=""

# ---------------------------------------------------------------------------
# Formerly-haiku agents that carried effort: low — Phase 3a removed it.
# bash-specialist is sonnet as of Phase 3a; same negative assertion applies.
# All agents in this section must NOT have an effort: line.
# ---------------------------------------------------------------------------

@test "bash-specialist does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/bash-specialist.md"
  assert_failure 1
}

@test "code-reviewer does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/code-reviewer.md"
  assert_failure 1
}

@test "commit does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/commit.md"
  assert_failure 1
}

@test "devops does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/devops.md"
  assert_failure 1
}

@test "docs does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/docs.md"
  assert_failure 1
}

@test "frontend-qa does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/frontend-qa.md"
  assert_failure 1
}

@test "morning-briefing does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/morning-briefing.md"
  assert_failure 1
}

@test "push does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/push.md"
  assert_failure 1
}

@test "test-runner does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/test-runner.md"
  assert_failure 1
}

@test "test-writer does NOT have effort field" {
  run grep -q "^effort:" "$AGENTS_DIR/test-writer.md"
  assert_failure 1
}

# ---------------------------------------------------------------------------
# Sonnet-tier agents: effort field MUST be absent (Task 3.4 / Phase 4).
# Only Opus reads the effort field; sonnet agents treat it as dead weight.
# ---------------------------------------------------------------------------

@test "debugger does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/debugger.md"
  assert_failure 1
}

@test "planner does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/planner.md"
  assert_failure 1
}

@test "backend-writer does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/backend-writer.md"
  assert_failure 1
}

@test "frontend-writer does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/frontend-writer.md"
  assert_failure 1
}

@test "researcher does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/researcher.md"
  assert_failure 1
}

@test "security does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/security.md"
  assert_failure 1
}

@test "api-contract does NOT have effort field (haiku — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/api-contract.md"
  assert_failure 1
}

@test "eval-writer does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/eval-writer.md"
  assert_failure 1
}

@test "pr-reviewer does NOT have effort field (sonnet — N/A)" {
  run grep -q "^effort:" "$AGENTS_DIR/pr-reviewer.md"
  assert_failure 1
}

# ---------------------------------------------------------------------------
# Opus exemption: migration-reviewer is opus — effort: high is intentional.
# ---------------------------------------------------------------------------

@test "migration-reviewer (opus) retains effort field" {
  grep -q "^effort:" "$AGENTS_DIR/migration-reviewer.md"
}

# ---------------------------------------------------------------------------
# Comprehensive sweep: every non-opus agent in agents/core/ and agents/personal/
# must NOT contain an effort: line in its frontmatter.
# Policy: effort field is only meaningful for opus. All non-opus agents (haiku
# and sonnet) must not have it. Opus exemption: migration-reviewer.md.
# ---------------------------------------------------------------------------

@test "no non-opus agent in agents/core/ has an effort: field" {
  local violations=()
  local count=0
  for f in "$AGENTS_DIR"/*.md; do
    count=$((count + 1))
    local name
    name="$(basename "$f")"
    # Extract model from frontmatter (lines between first pair of --- markers)
    local model
    model="$(awk '/^---/{p++} p==1 && /^model:/{print; exit}' "$f" | awk '{print $2}')"
    # Skip opus agents — they are the sole permitted exemption
    if [[ "$model" == "opus" ]]; then
      continue
    fi
    # Non-opus agents must not have effort: in frontmatter
    if awk '/^---/{p++} p>=2{exit} p==1 && /^effort:/{found=1} END{exit !found}' "$f"; then
      violations+=("$name (model: ${model:-unknown})")
    fi
  done
  if [[ "$count" -lt 10 ]]; then
    echo "Sweep iterated only $count agent files in $AGENTS_DIR (expected >= 10)"
    return 1
  fi
  if [[ ${#violations[@]} -gt 0 ]]; then
    echo "Non-opus agents with forbidden effort: field:"
    printf '  %s\n' "${violations[@]}"
    return 1
  fi
}

@test "no non-opus agent in agents/personal/ has an effort: field" {
  [[ -n "$PERSONAL_DIR" && -d "$PERSONAL_DIR" ]] || skip "agents/personal/ not present (Phase 4.5.3 archive)"
  local violations=()
  for f in "$PERSONAL_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    local name
    name="$(basename "$f")"
    local model
    model="$(awk '/^---/{p++} p==1 && /^model:/{print; exit}' "$f" | awk '{print $2}')"
    # Skip opus agents — they are the sole permitted exemption
    if [[ "$model" == "opus" ]]; then
      continue
    fi
    if awk '/^---/{p++} p>=2{exit} p==1 && /^effort:/{found=1} END{exit !found}' "$f"; then
      violations+=("$name (model: ${model:-unknown})")
    fi
  done
  if [[ ${#violations[@]} -gt 0 ]]; then
    echo "Non-opus agents in personal/ with forbidden effort: field:"
    printf '  %s\n' "${violations[@]}"
    return 1
  fi
}
