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

@test "code-reviewer.md Completion Report section has the Verdict template line" {
  run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/code-reviewer.md' | grep -cxF 'Verdict: <APPROVE or BLOCKED>'"
  assert_output "1"
}

@test "security.md Completion Report section has the Verdict template line" {
  run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/security.md' | grep -cxF 'Verdict: <APPROVE or BLOCKED>'"
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

# Print the first fenced block (the report template) of the Completion Report section.
completion_report_template() {
  completion_report_section "$1" | awk '/^```/ { n++; next } n == 1 { print }'
}

@test "Completion Report sections carry the exactly-once / last-line verdict rule" {
  for f in code-reviewer.md security.md; do
    run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/$f' | grep -cF 'exactly once'"
    assert_output "1"
    run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/$f' | grep -cF 'as the last line of your response'"
    assert_output "1"
  done
}

@test "report template ends with the Status line then the Verdict line" {
  for f in code-reviewer.md security.md; do
    run bash -c "$(declare -f completion_report_section completion_report_template); completion_report_template '$AGENTS_DIR/$f' | grep -v '^[[:space:]]*\$' | tail -2"
    assert_line --index 0 'Status: <DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT>'
    assert_line --index 1 'Verdict: <APPROVE or BLOCKED>'
  done
}

@test "Completion Report sections carry the json-status/Facts-before-closing-lines exception" {
  for f in code-reviewer.md security.md; do
    run bash -c "$(declare -f completion_report_section); completion_report_section '$AGENTS_DIR/$f' | grep -cF 'Reviewer exception to the cast-conventions Structured Output rule: emit the \`json status\` payload and any Facts block BEFORE your closing Status and verdict lines'"
    assert_output "1"
  done
}

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "reviewer definitions carry no parser-matching verdict text outside the template" {
  for f in code-reviewer.md security.md; do
    run python3 -I -c '
import sys, importlib.util
sp = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
t = open(sys.argv[2]).read()
i = t.index("## Completion Report"); a = t.index("```\n", i) + 4; b = t.index("\n```\n", a)
out = t[:a] + t[b:]
print(sum(1 for l in out.split("\n") if m._VERDICT_LINE_RE.search(m._normalise(l))))
' "$REPO_ROOT/scripts/cast_review_snapshot.py" "$AGENTS_DIR/$f"
    assert_output "0"
  done
}

# Build a report from the file's own template (closing two lines derived from the
# template's last two lines), then run parse_verdict + decide with the Status gate
# computed from the same text. argv: agent file, outcome (APPROVE|BLOCKED), drop-status (0|1).
parser_compat() {
  python3 -I -c '
import sys, re, importlib.util
def load(n, p):
    sp = importlib.util.spec_from_file_location(n, p); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); return m
root, agent, outcome, drop = sys.argv[1:5]
snap = load("snap", root + "/scripts/cast_review_snapshot.py")
stop = load("stop", root + "/scripts/cast_subagent_stop.py")
t = open(agent).read()
i = t.index("## Completion Report"); a = t.index("```\n", i) + 4; b = t.index("\n```\n", a)
tl = [l for l in t[a:b].split("\n") if l.strip()]
body, closing = tl[:-2], tl[-2:]
fill = {"Status:": "Status: DONE" if outcome == "APPROVE" else "Status: BLOCKED",
        "Verdict:": "Verdict: " + outcome}
out = []
for l in closing:
    k = l.split(" ")[0]
    out.append(fill[k])
if drop == "1":
    out = [l for l in out if not l.startswith("Status:")]
report = "\n".join(["Findings: none"] + body + ["", "```json status", "{\"status\": \"DONE\"}", "```", ""] + out) + "\n"
v = snap.parse_verdict(report)
g = stop.compute_gate_match(report, False)
print(snap.decide(v, g))
' "$REPO_ROOT" "$1" "$2" "$3"
}

@test "template-derived compliant reports parse as APPROVE / BLOCKED through parse_verdict + decide" {
  for f in code-reviewer.md security.md; do
    run parser_compat "$AGENTS_DIR/$f" APPROVE 0
    assert_output "APPROVE"
    run parser_compat "$AGENTS_DIR/$f" BLOCKED 0
    assert_output "BLOCKED"
    run parser_compat "$AGENTS_DIR/$f" APPROVE 1
    assert_output "BLOCKED"
  done
}
