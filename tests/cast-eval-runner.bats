#!/usr/bin/env bats
# Tests for scripts/cast-eval-runner.py (CAST A3 eval harness — Phase A)
#
# Coverage:
#   1.  run commit-missing-status-block with Status: DONE fixture → PASS, eval_runs row
#   2.  run commit-missing-status-block with no Status line → FAIL, eval_runs row
#   3.  run --dry-run → exit 0, prints DRY RUN header, NO eval_runs row
#   4a. honesty grader (agent_protocol_violations) — empty table → PASS
#       Proves the grader works against the REAL production schema (no ALTER TABLE workaround).
#       Real key column: agent_id  (not agent_run_id)
#   4b. honesty grader (agent_protocol_violations) — seeded violation (agent_id='') → FAIL
#   5a. hallucination grader (agent_hallucinations) — empty table → PASS
#   5b. hallucination grader — unverified row (verified=0) within --since window → FAIL
#   5c. hallucination grader — verified=1 row → does NOT count → PASS
#   5d. hallucination grader — row before --since window → does NOT count → PASS
#   6.  list → prints all 5 case IDs
#   7.  list --agent commit → only commit eval
#   8.  run non-existent id → exit 2
#   9.  tail grader — Status in last 200 lines → PASS
#   10. tail grader — no Status in tail → FAIL
#
# Real schema proof: tables come from cast-db-init.sh — NO ALTER TABLE workarounds.
# Test 4a explicitly asserts agent_id present AND agent_run_id absent.
# Isolation: setup_temp_home / teardown_temp_home — real ~/.claude never touched.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUNNER="$REPO_DIR/scripts/cast-eval-runner.py"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  export CAST_DB_PATH="$HOME/.cast-eval-test.db"
  # Initialize ALL tables with their REAL production schemas via cast-db-init.sh.
  # No manual CREATE TABLE or ALTER TABLE — what runs here matches production.
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  export CAST_EVAL_DIR="$REPO_DIR/evals/cases"
  export CAST_REPO_DIR="$REPO_DIR"
  export CAST_SESSION_ID="test-session-bats-$$"

  # R2 GUI-isolation: shim osascript (runner never calls it, safety net only).
  local shim_dir="$HOME/.shims"
  mkdir -p "$shim_dir"
  printf '#!/bin/sh\nexit 0\n' > "$shim_dir/osascript"
  chmod +x "$shim_dir/osascript"
  export PATH="$shim_dir:$PATH"
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH CAST_EVAL_DIR CAST_REPO_DIR CAST_SESSION_ID
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_count_eval_runs() {
  # _count_eval_runs <eval_id> <status>
  sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM eval_runs WHERE eval_id='${1}' AND status='${2}';"
}

# ---------------------------------------------------------------------------
# 1. Status line present → PASS, eval_runs row written
# ---------------------------------------------------------------------------

@test "run: Status: DONE fixture → PASS, eval_runs pass row written" {
  local fixture="$HOME/fixture_pass.txt"
  printf 'Some agent output\n\nStatus: DONE\nSummary: test\n' > "$fixture"

  run python3 "$RUNNER" run commit-missing-status-block --output-file "$fixture"

  assert_success
  assert_output --partial "PASS"
  assert_equal "$(_count_eval_runs 'commit-missing-status-block' 'pass')" "1"
}

# ---------------------------------------------------------------------------
# 2. No Status line → FAIL, eval_runs row written
# ---------------------------------------------------------------------------

@test "run: no Status line fixture → FAIL, eval_runs fail row written" {
  local fixture="$HOME/fixture_fail.txt"
  printf 'Response without any status block.\n' > "$fixture"

  run python3 "$RUNNER" run commit-missing-status-block --output-file "$fixture"

  assert_failure   # exit 1
  assert_output --partial "FAIL"
  assert_equal "$(_count_eval_runs 'commit-missing-status-block' 'fail')" "1"
}

# ---------------------------------------------------------------------------
# 3. --dry-run → exit 0, prints graders, NO eval_runs row
# ---------------------------------------------------------------------------

@test "run --dry-run: exit 0, lists graders, writes NO eval_runs row" {
  run python3 "$RUNNER" run commit-missing-status-block --dry-run

  assert_success
  assert_output --partial "DRY RUN"
  assert_output --partial "status-block-present"

  local total
  total="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM eval_runs;")"
  assert_equal "$total" "0"
}

# ---------------------------------------------------------------------------
# 4a. agent_protocol_violations grader — REAL schema proof
#     Table has agent_id column (not agent_run_id).
#     Empty table → grader queries agent_id='' → 0 rows → PASS.
# ---------------------------------------------------------------------------

@test "honesty grader (protocol_violations): real schema proven, empty table → PASS" {
  # Assert production schema: agent_id must exist, agent_run_id must NOT exist.
  local cols
  cols="$(sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_protocol_violations);" \
        | awk -F'|' '{print $2}' | tr '\n' ',')"
  [[ "$cols" == *"agent_id"* ]]
  [[ "$cols" != *"agent_run_id"* ]]

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  # --output-file mode → agent_run_id='' → grader queries WHERE agent_id=''
  run python3 "$RUNNER" run protocol-violation-prose-dispatch --output-file "$fixture"

  assert_success   # 0 rows → PASS
}

# ---------------------------------------------------------------------------
# 4b. agent_protocol_violations grader — seeded violation (agent_id='') → FAIL
# ---------------------------------------------------------------------------

@test "honesty grader (protocol_violations): seeded violation → FAIL" {
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_protocol_violations \
       (agent_type, violation, timestamp, agent_id) \
     VALUES ('code-writer', 'prose-dispatch', '${now}', '');"

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run protocol-violation-prose-dispatch --output-file "$fixture"

  assert_failure   # exit 1: 1 violation found
  assert_output --partial "FAIL"
}

# ---------------------------------------------------------------------------
# 5a. agent_hallucinations grader — empty table → PASS
# Grader uses {agent}='code-writer' and {since}=runner-start-time.
# ---------------------------------------------------------------------------

@test "hallucination grader: empty table → PASS" {
  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run hallucination-claimed-file-write --output-file "$fixture"

  assert_success   # 0 rows → PASS
}

# ---------------------------------------------------------------------------
# 5b. Unverified row (verified=0) within --since window → FAIL
# Timestamp far in the future (2099) ensures it is >= any runner start time.
# ---------------------------------------------------------------------------

@test "hallucination grader: unverified row within time window → FAIL" {
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_hallucinations \
       (agent_name, claim_type, claimed_value, verified, timestamp) \
     VALUES ('code-writer', 'file_write', 'scripts/ghost.py', 0, '2099-12-31T23:59:59Z');"

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run hallucination-claimed-file-write --output-file "$fixture"

  assert_failure   # exit 1: 1 unverified row
  assert_output --partial "FAIL"
}

# ---------------------------------------------------------------------------
# 5c. Verified=1 row → does NOT count as a violation → PASS
# The grader only counts rows where verified is falsey.
# ---------------------------------------------------------------------------

@test "hallucination grader: verified=1 row does NOT count → PASS" {
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_hallucinations \
       (agent_name, claim_type, claimed_value, verified, timestamp) \
     VALUES ('code-writer', 'file_write', 'scripts/verified.py', 1, '2099-12-31T23:59:59Z');"

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run hallucination-claimed-file-write --output-file "$fixture"

  assert_success   # verified=1 → not a violation → PASS
}

# ---------------------------------------------------------------------------
# 5d. Row before --since window → does NOT count → PASS
# Old hallucinations must not contaminate a new eval run.
# ---------------------------------------------------------------------------

@test "hallucination grader: row before --since window does NOT count → PASS" {
  # timestamp='2000-01-01T00:00:00Z' is always before the runner's start time.
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_hallucinations \
       (agent_name, claim_type, claimed_value, verified, timestamp) \
     VALUES ('code-writer', 'file_write', 'scripts/old.py', 0, '2000-01-01T00:00:00Z');"

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run hallucination-claimed-file-write --output-file "$fixture"

  assert_success   # old row outside --since window → 0 counted → PASS
}

# ---------------------------------------------------------------------------
# 6. list → all 5 case IDs
# ---------------------------------------------------------------------------

@test "list: returns all 5 eval case IDs" {
  run python3 "$RUNNER" list

  assert_success
  assert_output --partial "commit-missing-status-block"
  assert_output --partial "hallucination-claimed-file-write"
  assert_output --partial "protocol-violation-prose-dispatch"
  assert_output --partial "missing-handoff-block"
  assert_output --partial "silent-truncation-no-status-tail"
  assert_output --partial "5 case(s) found"
}

# ---------------------------------------------------------------------------
# 7. list --agent commit → only commit eval
# ---------------------------------------------------------------------------

@test "list --agent commit: returns only commit eval" {
  run python3 "$RUNNER" list --agent commit

  assert_success
  assert_output --partial "commit-missing-status-block"
  refute_output --partial "hallucination-claimed-file-write"
}

# ---------------------------------------------------------------------------
# 8. Unknown eval id → exit 2
# ---------------------------------------------------------------------------

@test "run: unknown eval ID → exit 2 with error message" {
  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run this-id-does-not-exist --output-file "$fixture"

  assert_output --partial "not found"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 9. tail grader — Status in last 200 lines → PASS
# ---------------------------------------------------------------------------

@test "tail grader: Status in last 200 lines → PASS" {
  local fixture="$HOME/fixture_tail_pass.txt"
  python3 -c "
for i in range(210):
    print(f'line {i}')
print('Status: DONE')
" > "$fixture"

  run python3 "$RUNNER" run silent-truncation-no-status-tail --output-file "$fixture"

  assert_success
  assert_output --partial "PASS"
}

# ---------------------------------------------------------------------------
# 10. tail grader — no Status in tail → FAIL
# ---------------------------------------------------------------------------

@test "tail grader: no Status in tail → FAIL" {
  local fixture="$HOME/fixture_tail_fail.txt"
  printf 'Truncated mid-sentence with no status.\n' > "$fixture"

  run python3 "$RUNNER" run silent-truncation-no-status-tail --output-file "$fixture"

  assert_failure
  assert_output --partial "FAIL"
}
