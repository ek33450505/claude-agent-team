#!/usr/bin/env bats
# Tests for scripts/cast-plan-doctor.py
#
# Coverage:
#   - Ledger parsing and validation (well-formed, next_count, order)
#   - Plan file detection and parsing
#   - --check exit codes and output
#   - --resume silent-exit on missing marker
#   - Bare-invocation default plan resolution (active-plan marker, then newest
#     top-level plans/*.md, then the literal next-session.md path)

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

# ---------------------------------------------------------------------------
# Default plan resolution (bare manual invocation, no --plan)
#
# Seam: the script derives REPO_ROOT from its own location (SCRIPT_DIR.parent),
# so these tests copy it into $HOME/sandbox-repo/scripts/ and populate
# $HOME/sandbox-repo/plans/ — no code seam needed. $HOME is the isolated temp
# HOME, so teardown_temp_home cleans the sandbox.
# ---------------------------------------------------------------------------

make_sandbox_repo() {
  SANDBOX="$HOME/sandbox-repo"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/plans/archive"
  cp "$DOCTOR" "$SANDBOX/scripts/cast-plan-doctor.py"
  SANDBOX_DOCTOR="$SANDBOX/scripts/cast-plan-doctor.py"
}

# write_plan <path> — minimal well-formed ledger: a done row on `main` plus a
# NEXT row (--resume only emits a briefing when a NEXT row exists, so without it
# the --resume tests below could not tell "silent by design" from "silent because
# the fixture is empty").
write_plan() {
  build_plan_md "| 1 | Phase A | U1 | P0 | main | ✅ Done |
| 2 | Phase B | U2 | P1 | feature/b1 | ☐ NEXT |" > "$1"
}

@test "plan-doctor default plan: active-plan marker wins over plans/*.md" {
  make_sandbox_repo
  mkdir -p "$HOME/elsewhere"
  write_plan "$HOME/elsewhere/marked.md"
  write_plan "$SANDBOX/plans/newer.md"
  touch -t 202001010000 "$HOME/elsewhere/marked.md"
  touch -t 202401010000 "$SANDBOX/plans/newer.md"
  printf '%s\n' "$HOME/elsewhere/marked.md" > "$HOME/.claude/config/active-plan"

  run python3 "$SANDBOX_DOCTOR" --json
  assert_success
  assert_output --partial "\"plan_path\": \"$HOME/elsewhere/marked.md\""
}

@test "plan-doctor default plan: no marker picks newest top-level plans/*.md, not archive/" {
  make_sandbox_repo
  write_plan "$SANDBOX/plans/old.md"
  write_plan "$SANDBOX/plans/new.md"
  write_plan "$SANDBOX/plans/archive/archived.md"
  touch -t 202001010000 "$SANDBOX/plans/old.md"
  touch -t 202401010000 "$SANDBOX/plans/new.md"
  touch -t 202601010000 "$SANDBOX/plans/archive/archived.md"

  run python3 "$SANDBOX_DOCTOR" --json
  assert_success
  assert_output --partial "\"plan_path\": \"$SANDBOX/plans/new.md\""
}

@test "plan-doctor default plan: stale marker falls through to newest plans/*.md" {
  make_sandbox_repo
  write_plan "$SANDBOX/plans/new.md"
  printf '%s\n' "$HOME/gone/missing.md" > "$HOME/.claude/config/active-plan"

  run python3 "$SANDBOX_DOCTOR" --json
  assert_success
  assert_output --partial "\"plan_path\": \"$SANDBOX/plans/new.md\""
}

@test "plan-doctor default plan: explicit --plan beats marker and plans/*.md" {
  make_sandbox_repo
  mkdir -p "$HOME/elsewhere"
  write_plan "$HOME/elsewhere/marked.md"
  write_plan "$SANDBOX/plans/newer.md"
  write_plan "$HOME/explicit.md"
  printf '%s\n' "$HOME/elsewhere/marked.md" > "$HOME/.claude/config/active-plan"

  run python3 "$SANDBOX_DOCTOR" --json --plan "$HOME/explicit.md"
  assert_success
  assert_output --partial "\"plan_path\": \"$HOME/explicit.md\""
}

@test "plan-doctor default plan: nothing resolvable keeps the next-session.md not-found error" {
  make_sandbox_repo
  # plans/ holds only archive/ content (skipped) — no marker, no top-level *.md
  write_plan "$SANDBOX/plans/archive/archived.md"

  run python3 "$SANDBOX_DOCTOR"
  assert_failure
  assert_output --partial "Plan file not found: $SANDBOX/plans/next-session.md"
}

@test "plan-doctor --resume: no marker stays silent even when plans/*.md exist" {
  make_sandbox_repo
  write_plan "$SANDBOX/plans/next-session.md"
  write_plan "$SANDBOX/plans/newer.md"

  run python3 "$SANDBOX_DOCTOR" --resume
  assert_success
  assert_output ""
}

@test "plan-doctor --resume: explicit --plan is honoured even when it equals the old default path" {
  make_sandbox_repo
  write_plan "$SANDBOX/plans/next-session.md"

  run python3 "$SANDBOX_DOCTOR" --resume --plan "$SANDBOX/plans/next-session.md"
  assert_success
  assert_output --partial "YOU ARE HERE"
  assert_output --partial "Canonical plan: $SANDBOX/plans/next-session.md"
}

@test "plan-doctor --resume: marker path is used when --plan is omitted" {
  make_sandbox_repo
  mkdir -p "$HOME/elsewhere"
  write_plan "$HOME/elsewhere/marked.md"
  write_plan "$SANDBOX/plans/newer.md"
  printf '%s\n' "$HOME/elsewhere/marked.md" > "$HOME/.claude/config/active-plan"

  run python3 "$SANDBOX_DOCTOR" --resume
  assert_success
  assert_output --partial "Canonical plan: $HOME/elsewhere/marked.md"
}
