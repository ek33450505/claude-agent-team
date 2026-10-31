#!/usr/bin/env bats
# tests/agents/commit-review-gate-pin.bats
# Pins the U4 review-gate wiring in agents/core/commit.md: the gate now runs in the
# PreToolUse git guard (WARN only), so the agent documents the REQUIRED commit shape and
# the explicit-reason hatch rule, and no longer runs `cast review-gate` itself.
# Reads the agent file only (no HOME writes).

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

COMMIT_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../agents/core" && pwd)/commit.md"

# Print the body of the "## Review Gate (U4" section (fence-aware).
review_gate_section() {
  awk '
    /^```/ { if (f) infence = !infence; if (f) print; next }
    !infence && /^## Review Gate \(U4/ { f = 1; next }
    !infence && /^## / { f = 0 }
    f { print }
  ' "$COMMIT_MD"
}

@test "commit.md has the Review Gate (U4 - WARN only) section heading" {
  run grep -c '^## Review Gate (U4 — WARN only, never blocks)$' "$COMMIT_MD"
  assert_output 1
}

@test "commit.md no longer instructs running cast review-gate or logging a Review gate: line" {
  run grep -cF 'cast review-gate' "$COMMIT_MD"
  assert_output 0
  run grep -cF 'Review gate:' "$COMMIT_MD"
  assert_output 0
}

@test "Review Gate section says the guard runs it, warn-only, and never blocks" {
  run review_gate_section
  assert_success
  assert_output --partial 'PreToolUse git guard'
  assert_output --partial 'WARN-only'
  assert_output --partial 'never blocks'
}

@test "Review Gate section documents the required commit shape" {
  run review_gate_section
  assert_output --partial 'CAST_COMMIT_AGENT=1 git [-C <repo-root>] commit -F <msg-file>'
  assert_output --partial 'FIRST command segment'
}

@test "Review Gate section documents the docs-only hatch shape with an explicit dispatch reason" {
  run review_gate_section
  assert_output --partial 'CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=<reason> git commit -F <msg-file>'
  assert_output --partial 'explicitly'
}

@test "hatch reason is restricted to a safe character set, else the hatch is skipped" {
  run grep -cF 'ONE UNQUOTED word of letters, digits and' "$COMMIT_MD"
  assert_output 1
  run grep -cF 'hatch skipped (unsafe reason)' "$COMMIT_MD"
  assert_output 1
}

@test "step 7 capture form uses literal paths and has no LOG variable" {
  run grep -cF 'CAST_COMMIT_AGENT=1 git commit -F <msg-file> > <log-path> 2>&1; rc=$?; echo "commit rc=$rc"' "$COMMIT_MD"
  assert_output 1
  run grep -cF '$LOG' "$COMMIT_MD"
  assert_output 0
}

@test "Approval Gate section is still present (Tier 2 untouched)" {
  run grep -cF '## Approval Gate' "$COMMIT_MD"
  assert_success
}
