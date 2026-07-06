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
  ! grep -q "^effort:" "$AGENTS_DIR/bash-specialist.md"
}

@test "code-reviewer does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/code-reviewer.md"
}

@test "commit does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/commit.md"
}

@test "devops does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/devops.md"
}

@test "docs does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/docs.md"
}

@test "frontend-qa does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/frontend-qa.md"
}

@test "morning-briefing does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/morning-briefing.md"
}

@test "push does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/push.md"
}

@test "test-runner does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/test-runner.md"
}

@test "test-writer does NOT have effort field" {
  ! grep -q "^effort:" "$AGENTS_DIR/test-writer.md"
}

# ---------------------------------------------------------------------------
# Sonnet-tier agents: effort field MUST be absent (Task 3.4 / Phase 4).
# Only Opus reads the effort field; sonnet agents treat it as dead weight.
# ---------------------------------------------------------------------------

@test "debugger does NOT have effort field (sonnet — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/debugger.md"
}

@test "planner does NOT have effort field (sonnet — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/planner.md"
}

@test "code-writer does NOT have effort field (sonnet — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/code-writer.md"
}

@test "researcher does NOT have effort field (sonnet — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/researcher.md"
}

@test "security does NOT have effort field (sonnet — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/security.md"
}

@test "api-contract does NOT have effort field (haiku — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/api-contract.md"
}

@test "eval-writer does NOT have effort field (sonnet — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/eval-writer.md"
}

@test "pr-reviewer does NOT have effort field (sonnet — N/A)" {
  ! grep -q "^effort:" "$AGENTS_DIR/pr-reviewer.md"
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
  for f in "$AGENTS_DIR"/*.md; do
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
