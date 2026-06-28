#!/usr/bin/env bats
# Tests for scripts/cast-plan-doctor.py
#
# Coverage:
#   - Ledger parsing and validation (well-formed, next_count, order)
#   - Plan file detection and parsing
#   - --check exit codes and output
#   - --resume silent-exit on missing marker

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOCTOR="${REPO}/scripts/cast-plan-doctor.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/config"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: build a markdown plan with a ledger table
# ---------------------------------------------------------------------------

build_plan_md() {
  local ledger_rows="$1"
  printf '%s\n' \
    "# Session Ledger" \
    "" \
    "| S# | Goal | Units | Phase | Branch | Status |" \
    "|----|----|----|----|----|----|" \
    "$ledger_rows"
}

# ---------------------------------------------------------------------------
# Test 1: Well-formed ledger (S1 done, S2 next, S3 todo)
# Self-contained: the DONE row uses `main` (present in every checkout, incl. a
# fresh CI clone). A done-row branch that is absent + unmerged would be flagged
# as a CONTRADICTION by probe_branch_reconcile; NEXT/Todo rows on absent feature
# branches are only INFO, so they don't affect --check.
# ---------------------------------------------------------------------------

@test "plan-doctor --check: well-formed ledger exits 0" {
  local plan_md plan_path
  plan_path="$BATS_TMPDIR/test-plan.md"
  plan_md="$(build_plan_md "| 1 | Phase A | U1 | P0 | main | ✅ Done |
| 2 | Phase B | U2 | P1 | feature/b1 | ☐ NEXT |
| 3 | Phase C | U3 | P2 | feature/c1 | ☐ Todo |")"
  printf '%s\n' "$plan_md" > "$plan_path"

  run python3 "$DOCTOR" --check --plan "$plan_path" --baseline /dev/null
  assert_success
  assert_output --partial "[PASS]"
}

# ---------------------------------------------------------------------------
# Test 2: Two NEXT rows → ledger:next_count error
# ---------------------------------------------------------------------------

@test "plan-doctor --check: two NEXT rows exits 1 with ledger:next_count" {
  local plan_md plan_path
  plan_path="$BATS_TMPDIR/test-plan-2next.md"
  plan_md="$(build_plan_md "| 1 | Phase A | U1 | P0 | feature/a1 | ✅ Done |
| 2 | Phase B | U2 | P1 | feature/b1 | ☐ NEXT |
| 3 | Phase C | U3 | P2 | feature/c1 | ☐ NEXT |")"
  printf '%s\n' "$plan_md" > "$plan_path"

  run python3 "$DOCTOR" --check --plan "$plan_path" --baseline /dev/null
  assert_failure
  assert_output --partial "ledger:next_count"
}

# ---------------------------------------------------------------------------
# Test 3: NEXT followed by DONE → ledger:order error
# ---------------------------------------------------------------------------

@test "plan-doctor --check: done after next exits 1 with ledger:order" {
  local plan_md plan_path
  plan_path="$BATS_TMPDIR/test-plan-order.md"
  plan_md="$(build_plan_md "| 1 | Phase A | U1 | P0 | feature/a1 | ✅ Done |
| 2 | Phase B | U2 | P1 | feature/b1 | ☐ NEXT |
| 3 | Phase C | U3 | P2 | feature/c1 | ✅ Done |")"
  printf '%s\n' "$plan_md" > "$plan_path"

  run python3 "$DOCTOR" --check --plan "$plan_path" --baseline /dev/null
  assert_failure
  assert_output --partial "ledger:order"
}

# ---------------------------------------------------------------------------
# Test 4: Markdown with no ledger table → plan:unparseable
# ---------------------------------------------------------------------------

@test "plan-doctor --check: no ledger table exits 1 with plan:unparseable" {
  local plan_path
  plan_path="$BATS_TMPDIR/no-table.md"
  printf '%s\n' \
    "# No Ledger Here" \
    "" \
    "Just some prose." > "$plan_path"

  run python3 "$DOCTOR" --check --plan "$plan_path" --baseline /dev/null
  assert_failure
  assert_output --partial "plan:unparseable"
}

# ---------------------------------------------------------------------------
# Test 5: --resume with no marker → silent exit 0, no output
# ---------------------------------------------------------------------------

@test "plan-doctor --resume: no marker exits 0 silent" {
  # No active-plan marker in temp HOME
  run python3 "$DOCTOR" --resume
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Test 6: --json mode emits valid JSON
# ---------------------------------------------------------------------------

@test "plan-doctor --json: emits valid JSON" {
  local plan_md plan_path
  plan_path="$BATS_TMPDIR/test-plan-json.md"
  plan_md="$(build_plan_md "| 1 | Phase A | U1 | P0 | feature/a1 | ✅ Done |
| 2 | Phase B | U2 | P1 | feature/b1 | ☐ NEXT |")"
  printf '%s\n' "$plan_md" > "$plan_path"

  run python3 "$DOCTOR" --json --plan "$plan_path"
  assert_success
  # Parse JSON to verify structure
  run python3 -c "import json; data = json.loads('''$output'''); assert 'ledger' in data and isinstance(data['ledger'], list)"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 7: Empty ledger table → ledger:empty error
# ---------------------------------------------------------------------------

@test "plan-doctor --check: empty ledger exits 1 with ledger:empty" {
  local plan_path
  plan_path="$BATS_TMPDIR/empty-ledger.md"
  printf '%s\n' \
    "# Session Ledger" \
    "" \
    "| S# | Goal | Units | Phase | Branch | Status |" \
    "|----|----|----|----|----|----|" > "$plan_path"

  run python3 "$DOCTOR" --check --plan "$plan_path" --baseline /dev/null
  assert_failure
  assert_output --partial "ledger:empty"
}
