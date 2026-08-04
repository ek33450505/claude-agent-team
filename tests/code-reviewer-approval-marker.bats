#!/usr/bin/env bats
#
# Regression test for T0.1: the code-reviewer approval-marker write
# (agents/core/code-reviewer.md -> "Mandatory Final Step — Approval Marker
# (orchestrated dispatch only)") must be gated on TASK_ID being set. In
# ad-hoc/manual dispatch TASK_ID is unset, and an unguarded write caused
# code-reviewer to self-author an "approved" review record, tripping the
# harness self-approval guard on ~6 of 7 manual review gates.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Mirror the real runtime layout so the guarded snippet's literal
  # `source ~/.claude/scripts/cast-events.sh` resolves inside the isolated HOME.
  mkdir -p "$HOME/.claude/scripts"
  cp "$REPO_DIR/scripts/cast-events.sh" "$HOME/.claude/scripts/cast-events.sh"

  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  # cast-events.sh falls back to a macOS Keychain lookup (`security
  # find-generic-password`) only when ANTHROPIC_API_KEY is unset on Darwin.
  # Pre-set it so sourcing the script never touches the real Keychain
  # (GUI-prompt isolation — same rationale as the notify/osascript PATH-shim rule).
  export ANTHROPIC_API_KEY="test-dummy-key-not-real"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Reproduces the EXACT guarded snippet from agents/core/code-reviewer.md's
# "Mandatory Final Step — Approval Marker (orchestrated dispatch only)".
run_guarded_marker_snippet() {
  run bash -c '
    if [ -n "${TASK_ID:-}" ]; then
      source ~/.claude/scripts/cast-events.sh
      cast_write_review "$TASK_ID" "code-reviewer" "approved" "Review complete" ""
      cast_derive_state "$TASK_ID"
    fi
  '
}

review_file_count() {
  find "$HOME/.claude/cast/reviews" -type f -name '*code-reviewer*' 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "guarded marker snippet: TASK_ID unset (ad-hoc dispatch) writes no review artifact" {
  unset TASK_ID
  run_guarded_marker_snippet
  assert_success
  [ "$(review_file_count)" = "0" ]
}

@test "guarded marker snippet: TASK_ID set (orchestrated dispatch) writes the review artifact" {
  export TASK_ID="some-real-id"
  run_guarded_marker_snippet
  assert_success
  [ "$(review_file_count)" = "1" ]

  local review_file
  review_file="$(find "$HOME/.claude/cast/reviews" -type f -name '*code-reviewer*' 2>/dev/null | head -1)"
  [ -n "$review_file" ]

  python3 - "$review_file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d["artifact_id"] == "some-real-id", d
assert d["reviewer"] == "code-reviewer", d
assert d["decision"] == "approved", d
PYEOF
}

# Reproduces the EXACT guarded snippet from agents/core/security.md's
# "Mandatory Final Step — Approval Marker (orchestrated dispatch only)"
# (identical TASK_ID gate, "security" reviewer args).
run_guarded_marker_snippet_security() {
  run bash -c '
    if [ -n "${TASK_ID:-}" ]; then
      source ~/.claude/scripts/cast-events.sh
      cast_write_review "$TASK_ID" "security" "approved" "Security review complete" ""
      cast_derive_state "$TASK_ID"
    fi
  '
}

security_review_file_count() {
  find "$HOME/.claude/cast/reviews" -type f -name '*security*' 2>/dev/null | wc -l | tr -d ' '
}

@test "guarded marker snippet (security.md): TASK_ID unset writes nothing, TASK_ID set writes the review artifact" {
  unset TASK_ID
  run_guarded_marker_snippet_security
  assert_success
  [ "$(security_review_file_count)" = "0" ]

  export TASK_ID="some-real-id-security"
  run_guarded_marker_snippet_security
  assert_success
  [ "$(security_review_file_count)" = "1" ]

  local review_file
  review_file="$(find "$HOME/.claude/cast/reviews" -type f -name '*security*' 2>/dev/null | head -1)"
  [ -n "$review_file" ]

  python3 - "$review_file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d["artifact_id"] == "some-real-id-security", d
assert d["reviewer"] == "security", d
assert d["decision"] == "approved", d
PYEOF
}
