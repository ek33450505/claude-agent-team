#!/usr/bin/env bats
# tests/agents/commit-review-gate-pin.bats
# Pins the G1 WARN-only review-gate wiring in agents/core/commit.md: the exact
# command, the section, the never-blocks contract, the Work Log field and the
# explicit-reason hatch rule. Reads the agent file only (no HOME writes).

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

COMMIT_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../agents/core" && pwd)/commit.md"

# Print the body of the "## Review Gate (G1" section (fence-aware).
review_gate_section() {
  awk '
    /^```/ { if (f) infence = !infence; if (f) print; next }
    !infence && /^## Review Gate \(G1/ { f = 1; next }
    !infence && /^## / { f = 0 }
    f { print }
  ' "$COMMIT_MD"
}

@test "commit.md carries the exact review-gate command" {
  run grep -cFx 'cast review-gate' "$COMMIT_MD"
  assert_success
  # The old direct-script form names ~/.claude/scripts, which the protected-write
  # guard blocks; it must not come back.
  run grep -cF '.claude/scripts/cast-review-gate.py' "$COMMIT_MD"
  assert_output 0
}

@test "commit.md has the Review Gate (G1 - WARN only) section heading" {
  run grep -c '^## Review Gate (G1 — WARN only, never blocks)$' "$COMMIT_MD"
  assert_output 1
}

@test "Review Gate section says it never blocks and puts the command inside it" {
  run review_gate_section
  assert_success
  assert_output --partial 'never blocks'
  assert_output --partial 'cast review-gate'
}

@test "Work Log template has a Review gate: field" {
  run grep -cF -- '- Review gate: [verbatim review-gate line | not run (<reason>)]' "$COMMIT_MD"
  assert_output 1
}

@test "hatch sentence names CAST_UNREVIEWED_OK and requires an explicit dispatch reason" {
  run bash -c "grep -F 'CAST_UNREVIEWED_OK' '$COMMIT_MD' | grep -F 'explicitly'"
  assert_success
}

@test "hatch reason is restricted to a safe character set, else the hatch is skipped" {
  run grep -cF 'letters, digits, spaces' "$COMMIT_MD"
  assert_output 1
  run grep -cF 'hatch skipped (unsafe reason)' "$COMMIT_MD"
  assert_output 1
}

@test "Approval Gate section is still present (Tier 2 untouched)" {
  run grep -cF '## Approval Gate' "$COMMIT_MD"
  assert_success
}
