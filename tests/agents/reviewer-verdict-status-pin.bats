#!/usr/bin/env bats
# tests/agents/reviewer-verdict-status-pin.bats
# Pins the reviewer verdict/status contract in code-reviewer.md and security.md.
# The commit gate (cast_check_approvals) reads only the Status line, never a
# Verdict line, so a BLOCKED verdict must be tied to Status: BLOCKED for EVERY
# dispatch (not only orchestrated ones). The coupling therefore has to live in the
# Completion Report section, outside the "orchestrated dispatch only" Approval
# Marker section. Reviewers once put APPROVE / CHANGES_REQUESTED in `status:`.

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

AGENTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../agents/core" && pwd)"

# Print the body of the "## Completion Report" section of $1. Fence-aware: the
# report template contains a literal "## Work Log" line INSIDE a code fence, which
# must not be mistaken for the next heading.
completion_report_section() {
  awk '
    /^```/ { if (f) infence = !infence; if (f) print; next }
    !infence && /^## Completion Report/ { f = 1; next }
    !infence && /^## / { f = 0 }
    f { print }
  ' "$1"
}

# Print the body of the Approval Marker section of $1 (same fence-awareness).
approval_marker_section() {
  awk '
    /^```/ { if (f) infence = !infence; if (f) print; next }
    !infence && /^## Mandatory Final Step/ { f = 1; next }
    !infence && /^## / { f = 0 }
    f { print }
  ' "$1"
}

@test "code-reviewer.md Completion Report section carries the Verdict/Status coupling" {
  run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/code-reviewer.md' | grep -cF 'REQUIRES \`Status: BLOCKED\`'"
  assert_output "1"
}

@test "security.md Completion Report section carries the Verdict/Status coupling" {
  run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/security.md' | grep -cF 'REQUIRES \`Status: BLOCKED\`'"
  assert_output "1"
}

@test "code-reviewer.md Completion Report section has the Verdict: APPROVE | BLOCKED line" {
  run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/code-reviewer.md' | grep -cxF 'Verdict: APPROVE | BLOCKED'"
  assert_output "1"
}

@test "security.md Completion Report section has the Verdict: APPROVE | BLOCKED line" {
  run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/security.md' | grep -cxF 'Verdict: APPROVE | BLOCKED'"
  assert_output "1"
}

@test "Approval Marker sections defer to the coupling instead of restating it" {
  for f in code-reviewer.md security.md; do
    run bash -c "$(declare -f approval_marker_section); approval_marker_section '$AGENTS_DIR/$f' | grep -cF 'Follow the Verdict/Status coupling in the Completion Report section.'"
    assert_output "1"
    run bash -c "$(declare -f approval_marker_section); approval_marker_section '$AGENTS_DIR/$f' | grep -cF 'REQUIRES'"
    assert_output "0"
  done
}

@test "neither reviewer definition still offers CHANGES_REQUESTED as a verdict" {
  run grep -c 'CHANGES_REQUESTED' "$AGENTS_DIR/code-reviewer.md" "$AGENTS_DIR/security.md"
  assert_line "$AGENTS_DIR/code-reviewer.md:0"
  assert_line "$AGENTS_DIR/security.md:0"
}
