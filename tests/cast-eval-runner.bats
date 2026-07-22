#!/usr/bin/env bats
# Tests for scripts/cast-eval-runner.py (CAST A3 eval harness — Phase A + Phase B)
#
# Phase A coverage:
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
#   6.  list → prints Phase-A anchor case IDs
#   7.  list --agent commit → only commit eval
#   8.  run non-existent id → exit 2
#   9.  tail grader — Status in last 200 lines → PASS
#   10. tail grader — no Status in tail → FAIL
#
# Phase B coverage:
#   11. llm_judge: CAST_EVAL_JUDGE_CMD → Verdict: confirmed → PASS
#   12. llm_judge: CAST_EVAL_JUDGE_CMD → Verdict: refuted → FAIL
#   13. llm_judge: CAST_EVAL_JUDGE_CMD → Verdict: unverified → NOT fail (error/skip)
#   14. llm_judge: CAST_EVAL_JUDGE_CMD → empty/garbage → NOT fail (error/skip)
#   15. pass@k=3: all pass → pass_at_k=1.0, eval_runs has 3 attempt rows
#   16. pass@k=3: all fail → pass_at_k=0.0, overall FAIL
#   17. cost_tier cheap default k=1; medium default k=3 (with stub grader)
#   18. cast eval report: table absent → INFO message, exit 0
#   19. cast eval report: empty eval_runs → "No eval runs found", exit 0
#   20. cast eval report: seeded row → shows table output, exit 0
#   21. cast eval report --format json: seeded row → valid JSON, exit 0
#   22. cast eval record: creates recording file in evals/recordings/
#   23. cost_tier expensive → default k=1 without --expensive flag (cost guard)
#   24. cost_tier expensive → k=5 with --expensive flag
#
# Real schema proof: tables come from cast-db-init.sh — NO ALTER TABLE workarounds.
# Test 4a explicitly asserts agent_id present AND agent_run_id absent.
# Isolation: setup_temp_home / teardown_temp_home — real ~/.claude never touched.
# GUI isolation: osascript shimmed to no-op (R2 rule).

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
  unset CAST_DB_PATH CAST_EVAL_DIR CAST_REPO_DIR CAST_SESSION_ID CAST_EVAL_JUDGE_CMD
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_count_eval_runs() {
  # _count_eval_runs <eval_id> <status>
  sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM eval_runs WHERE eval_id='${1}' AND status='${2}';"
}

_count_eval_runs_attempt() {
  # _count_eval_runs_attempt <eval_id> <attempt>
  sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM eval_runs WHERE eval_id='${1}' AND attempt=${2};"
}

_get_pass_at_k() {
  # _get_pass_at_k <eval_id>  — returns pass_at_k from the final attempt row
  sqlite3 "$CAST_DB_PATH" \
    "SELECT pass_at_k FROM eval_runs WHERE eval_id='${1}' ORDER BY attempt DESC LIMIT 1;"
}

# Write a temp eval YAML with an llm_judge grader to a temp CAST_EVAL_DIR.
# Usage: _setup_judge_eval_dir <verdict-stub-cmd>
# Sets CAST_EVAL_DIR to a temp dir containing judge-quality-test.yaml.
_setup_judge_eval_dir() {
  local stub_cmd="${1:-echo 'Verdict: confirmed'}"
  local tmpdir
  tmpdir="$(mktemp -d "$HOME/eval_judge_XXXXXX")"

  cat > "$tmpdir/judge-quality-test.yaml" <<YAML
id: judge-quality-test
version: "1"
agent: code-writer
description: "LLM judge grader test"
corpus_source: manual
failure_type: commit_message_quality
cost_tier: cheap
tags: [test, llm_judge]
trigger: |
  Write a commit message for the staged changes.
expected_behaviors:
  - "Commit message in imperative mood"
forbidden_behaviors:
  - "No commit message"
graders:
  - id: judge-commit-quality
    type: llm_judge
    model: haiku
    prompt: |
      Did this agent produce a good commit message?
      Output: {output}
    pass_criteria: confirmed
    on_error: error
    votes: 1
YAML

  export CAST_EVAL_DIR="$tmpdir"
  export CAST_EVAL_JUDGE_CMD="$stub_cmd"
}

# Write a cheap-tier eval YAML for pass@k tests.
# Uses a programmatic grader that checks for "PASS_MARKER" in the output.
_setup_passatk_eval_dir() {
  local tmpdir
  tmpdir="$(mktemp -d "$HOME/eval_passatk_XXXXXX")"

  cat > "$tmpdir/passatk-test.yaml" <<YAML
id: passatk-test
version: "1"
agent: code-writer
description: "pass@k test"
corpus_source: manual
failure_type: missing_status_block
cost_tier: cheap
tags: [test, passatk]
pass_threshold: 0.5
trigger: |
  Do something.
expected_behaviors:
  - "Contains PASS_MARKER"
forbidden_behaviors:
  - "Missing PASS_MARKER"
graders:
  - id: marker-present
    type: programmatic
    command: "grep -q PASS_MARKER '{output_file}'"
    pass_criteria: exit_code_0
    on_error: error
YAML

  export CAST_EVAL_DIR="$tmpdir"
}

# Write an expensive-tier eval YAML (default k=5, but gated behind --expensive).
_setup_expensive_tier_eval_dir() {
  local tmpdir
  tmpdir="$(mktemp -d "$HOME/eval_expensive_XXXXXX")"

  cat > "$tmpdir/expensive-test.yaml" <<YAML
id: expensive-test
version: "1"
agent: code-writer
description: "expensive tier default k test"
corpus_source: manual
failure_type: missing_status_block
cost_tier: expensive
tags: [test, expensive]
pass_threshold: 0.5
trigger: |
  Do something.
expected_behaviors:
  - "Contains PASS_MARKER"
forbidden_behaviors:
  - "Missing PASS_MARKER"
graders:
  - id: marker-present
    type: programmatic
    command: "grep -q PASS_MARKER '{output_file}'"
    pass_criteria: exit_code_0
    on_error: error
YAML

  export CAST_EVAL_DIR="$tmpdir"
}

# Write a medium-tier eval YAML (default k=3).
_setup_medium_tier_eval_dir() {
  local tmpdir
  tmpdir="$(mktemp -d "$HOME/eval_medium_XXXXXX")"

  cat > "$tmpdir/medium-test.yaml" <<YAML
id: medium-test
version: "1"
agent: code-writer
description: "medium tier default k=3 test"
corpus_source: manual
failure_type: missing_status_block
cost_tier: medium
tags: [test, medium]
pass_threshold: 0.5
trigger: |
  Do something.
expected_behaviors:
  - "Contains PASS_MARKER"
forbidden_behaviors:
  - "Missing PASS_MARKER"
graders:
  - id: marker-present
    type: programmatic
    command: "grep -q PASS_MARKER '{output_file}'"
    pass_criteria: exit_code_0
    on_error: error
YAML

  export CAST_EVAL_DIR="$tmpdir"
}

# ---------------------------------------------------------------------------
# ── Phase A tests (regression guard) ────────────────────────────────────────
# ---------------------------------------------------------------------------

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
  run python3 "$RUNNER" run backend-writer-protocol-violation-prose-dispatch --output-file "$fixture"

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

  run python3 "$RUNNER" run backend-writer-protocol-violation-prose-dispatch --output-file "$fixture"

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

  run python3 "$RUNNER" run backend-writer-hallucination-claimed-file-write --output-file "$fixture"

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
     VALUES ('backend-writer', 'file_write', 'scripts/ghost.py', 0, '2099-12-31T23:59:59Z');"

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run backend-writer-hallucination-claimed-file-write --output-file "$fixture"

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
     VALUES ('backend-writer', 'file_write', 'scripts/verified.py', 1, '2099-12-31T23:59:59Z');"

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run backend-writer-hallucination-claimed-file-write --output-file "$fixture"

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
     VALUES ('backend-writer', 'file_write', 'scripts/old.py', 0, '2000-01-01T00:00:00Z');"

  local fixture="$HOME/fixture_any.txt"
  printf 'placeholder\n' > "$fixture"

  run python3 "$RUNNER" run backend-writer-hallucination-claimed-file-write --output-file "$fixture"

  assert_success   # old row outside --since window → 0 counted → PASS
}

# ---------------------------------------------------------------------------
# 6. list → Phase-A anchor case IDs present, total count ≥ 5
# ---------------------------------------------------------------------------

@test "list: returns all Phase-A anchor eval case IDs" {
  run python3 "$RUNNER" list

  assert_success
  assert_output --partial "commit-missing-status-block"
  assert_output --partial "hallucination-claimed-file-write"
  assert_output --partial "protocol-violation-prose-dispatch"
  assert_output --partial "missing-handoff-block"
  assert_output --partial "silent-truncation-no-status-tail"
  assert_output --partial "case(s) found"
  # corpus grows over time; assert at least the 5 Phase-A anchor cases are counted
  count="$(printf '%s\n' "$output" | sed -n 's/^\([0-9]\{1,\}\) case(s) found.*/\1/p' | head -1)"
  [ "${count:-0}" -ge 5 ]
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

# ---------------------------------------------------------------------------
# ── Phase B tests ────────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 11. llm_judge: Verdict: confirmed → PASS
# CAST_EVAL_JUDGE_CMD stub echoes a canned response without real model/network.
# ---------------------------------------------------------------------------

@test "llm_judge: Verdict: confirmed → PASS" {
  _setup_judge_eval_dir "echo 'Verdict: confirmed'"

  local fixture="$HOME/fixture_judge.txt"
  printf 'Good commit message: Add feature X\n' > "$fixture"

  run python3 "$RUNNER" run judge-quality-test --output-file "$fixture"

  assert_success
  assert_output --partial "PASS"
}

# ---------------------------------------------------------------------------
# 12. llm_judge: Verdict: refuted → FAIL (1 vote, refutations_required=1)
# ---------------------------------------------------------------------------

@test "llm_judge: Verdict: refuted → FAIL" {
  _setup_judge_eval_dir "echo 'Verdict: refuted'"

  local fixture="$HOME/fixture_judge.txt"
  printf 'Bad commit message\n' > "$fixture"

  run python3 "$RUNNER" run judge-quality-test --output-file "$fixture"

  assert_failure
  assert_output --partial "FAIL"
}

# ---------------------------------------------------------------------------
# 13. llm_judge: Verdict: unverified → NOT fail (must be error or skip)
# Three-outcome discipline: unverified MUST NOT be recorded as fail.
# ---------------------------------------------------------------------------

@test "llm_judge: Verdict: unverified → NOT fail (error or skip)" {
  _setup_judge_eval_dir "echo 'Verdict: unverified'"

  local fixture="$HOME/fixture_judge.txt"
  printf 'Ambiguous output\n' > "$fixture"

  run python3 "$RUNNER" run judge-quality-test --output-file "$fixture"

  # Must NOT be exit 1 (fail). exit 0 (skip/pass) or exit 2 (error) are both OK.
  [ "$status" -ne 1 ]
  # Must not print FAIL
  refute_output --partial "FAIL"
}

# ---------------------------------------------------------------------------
# 14. llm_judge: empty/garbage response → NOT fail (error or skip)
# Three-outcome discipline: parse failure → unverified, never fail.
# ---------------------------------------------------------------------------

@test "llm_judge: empty/garbage response → NOT fail (error or skip)" {
  _setup_judge_eval_dir "echo 'this is not a verdict line at all'"

  local fixture="$HOME/fixture_judge.txt"
  printf 'some output\n' > "$fixture"

  run python3 "$RUNNER" run judge-quality-test --output-file "$fixture"

  # Must NOT be exit 1 (fail). Garbage → unverified → error/skip → exit 0 or 2.
  [ "$status" -ne 1 ]
  refute_output --partial "FAIL"
}

# ---------------------------------------------------------------------------
# 15. pass@k=3: all pass → pass_at_k=1.0, 3 attempt rows in eval_runs
# Uses a grader that always passes (PASS_MARKER present in fixture).
# ---------------------------------------------------------------------------

@test "pass@k=3: all pass → pass_at_k=1.0, 3 eval_runs rows" {
  _setup_passatk_eval_dir

  local fixture="$HOME/fixture_passatk_pass.txt"
  printf 'PASS_MARKER is here\n' > "$fixture"

  run python3 "$RUNNER" run passatk-test --output-file "$fixture" --k 3

  assert_success
  assert_output --partial "PASS"
  assert_output --partial "pass@3"

  # Should have 3 attempt rows for this eval_id
  local row_count
  row_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM eval_runs WHERE eval_id='passatk-test';")"
  assert_equal "$row_count" "3"

  # Final attempt (attempt=3) should have pass_at_k set
  local pak
  pak="$(_get_pass_at_k 'passatk-test')"
  # pass_at_k=1.0 (all 3 pass)
  [[ "$pak" == "1.0" ]]
}

# ---------------------------------------------------------------------------
# 16. pass@k=3: all fail → pass_at_k=0.0, overall FAIL
# ---------------------------------------------------------------------------

@test "pass@k=3: all fail → overall FAIL" {
  _setup_passatk_eval_dir

  local fixture="$HOME/fixture_passatk_fail.txt"
  printf 'No marker here at all\n' > "$fixture"

  run python3 "$RUNNER" run passatk-test --output-file "$fixture" --k 3

  assert_failure   # exit 1: pass_at_k=0.0 < 0.5 threshold → FAIL
  assert_output --partial "FAIL"

  # 3 attempt rows should exist
  local row_count
  row_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM eval_runs WHERE eval_id='passatk-test';")"
  assert_equal "$row_count" "3"

  # Final attempt has pass_at_k=0.0
  local pak
  pak="$(_get_pass_at_k 'passatk-test')"
  [[ "$pak" == "0.0" ]]
}

# ---------------------------------------------------------------------------
# 17. cost_tier defaults: cheap→k=1, medium→k=3 (with --k not set)
# Uses stub grader + PASS_MARKER fixture so all attempts pass quickly.
# ---------------------------------------------------------------------------

@test "cost_tier cheap → default k=1 (one eval_runs row)" {
  _setup_passatk_eval_dir

  local fixture="$HOME/fixture_cheap.txt"
  printf 'PASS_MARKER\n' > "$fixture"

  # cheap tier, no --k flag
  run python3 "$RUNNER" run passatk-test --output-file "$fixture"

  assert_success

  local row_count
  row_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM eval_runs WHERE eval_id='passatk-test';")"
  assert_equal "$row_count" "1"
}

@test "cost_tier medium → default k=3 (three eval_runs rows)" {
  _setup_medium_tier_eval_dir

  local fixture="$HOME/fixture_medium.txt"
  printf 'PASS_MARKER\n' > "$fixture"

  # medium tier, no --k flag → should default to k=3
  run python3 "$RUNNER" run medium-test --output-file "$fixture"

  assert_success

  local row_count
  row_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM eval_runs WHERE eval_id='medium-test';")"
  assert_equal "$row_count" "3"
}

# ---------------------------------------------------------------------------
# 18. cast eval report: eval_runs table absent → INFO message, exit 0
# Test against a fresh empty DB that hasn't had cast-db-init run.
# ---------------------------------------------------------------------------

@test "eval report: table absent → INFO message, exit 0" {
  # Point to a non-existent DB so the table is definitely absent.
  local empty_db="$HOME/.empty-test.db"
  sqlite3 "$empty_db" "SELECT 1;" >/dev/null 2>&1 || true
  # Do NOT run cast-db-init — the table should be absent.

  CAST_DB_PATH="$empty_db" run python3 "$RUNNER" report

  assert_success   # exit 0 — honest degradation
  # Output should contain INFO (to stderr) but not crash
  # (bats combines stdout+stderr in $output)
  assert_output --partial "INFO"
}

# ---------------------------------------------------------------------------
# 19. cast eval report: table present, no rows → "No eval runs found", exit 0
# ---------------------------------------------------------------------------

@test "eval report: empty eval_runs → 'No eval runs found', exit 0" {
  # DB has the eval_runs table (cast-db-init ran in setup) but no rows.
  run python3 "$RUNNER" report

  assert_success
  assert_output --partial "No eval runs found"
}

# ---------------------------------------------------------------------------
# 20. cast eval report: seeded row → shows table output
# ---------------------------------------------------------------------------

@test "eval report: seeded row → shows table output" {
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO eval_runs (id, eval_id, agent, attempt, status, k, pass_at_k, ended_at, started_at, duration_ms, cost_tier, model, agent_run_id, grader_results) \
     VALUES ('test-uuid-1', 'commit-missing-status-block', 'commit', 1, 'pass', 1, 1.0, '${now}', '${now}', 100, 'cheap', '', '', '[]');"

  run python3 "$RUNNER" report

  assert_success
  assert_output --partial "commit-missing-status-block"
  assert_output --partial "commit"
  assert_output --partial "pass"
}

# ---------------------------------------------------------------------------
# 21. cast eval report --format json: seeded row → valid JSON, exit 0
# ---------------------------------------------------------------------------

@test "eval report --format json: seeded row → valid JSON" {
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO eval_runs (id, eval_id, agent, attempt, status, k, pass_at_k, ended_at, started_at, duration_ms, cost_tier, model, agent_run_id, grader_results) \
     VALUES ('test-uuid-2', 'commit-missing-status-block', 'commit', 1, 'pass', 1, 1.0, '${now}', '${now}', 100, 'cheap', '', '', '[]');"

  run python3 "$RUNNER" report --format json

  assert_success

  # Validate that output is valid JSON using python3
  local json_valid
  json_valid="$(echo "$output" | python3 -c "import sys,json; json.load(sys.stdin); print('ok')" 2>&1)"
  assert_equal "$json_valid" "ok"
}

# ---------------------------------------------------------------------------
# 22. cast eval record: creates recording file in evals/recordings/
# Uses --output-file to avoid live dispatch.
# ---------------------------------------------------------------------------

@test "eval record: creates recording file in evals/recordings/" {
  local fixture="$HOME/fixture_record.txt"
  printf 'Status: DONE\nSummary: recorded\n' > "$fixture"

  run python3 "$RUNNER" record commit-missing-status-block --output-file "$fixture"

  # Should succeed (Status: DONE in fixture → grader passes)
  assert_success

  # Recording file should exist under evals/recordings/
  local rec_count
  rec_count="$(find "$REPO_DIR/evals/recordings" -name "commit-missing-status-block-*.txt" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$rec_count" -ge 1 ]

  # Clean up the recording file created by this test
  find "$REPO_DIR/evals/recordings" -name "commit-missing-status-block-*.txt" -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 23. cost_tier expensive → default k=1 WITHOUT --expensive (gated)
# Without --expensive the runner falls back to k=1 (not k=5) as a cost guard.
# ---------------------------------------------------------------------------

@test "cost_tier expensive → default k=1 without --expensive flag" {
  _setup_expensive_tier_eval_dir

  local fixture="$HOME/fixture_expensive_no_flag.txt"
  printf 'PASS_MARKER\n' > "$fixture"

  # No --expensive flag → should resolve k=1
  run python3 "$RUNNER" run expensive-test --output-file "$fixture"

  assert_success

  local row_count
  row_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM eval_runs WHERE eval_id='expensive-test';")"
  assert_equal "$row_count" "1"
}

# ---------------------------------------------------------------------------
# 24. cost_tier expensive → k=5 WITH --expensive flag
# Verifies the --expensive gate opens k=5 for expensive-tier evals.
# ---------------------------------------------------------------------------

@test "cost_tier expensive → k=5 with --expensive flag" {
  _setup_expensive_tier_eval_dir

  local fixture="$HOME/fixture_expensive_with_flag.txt"
  printf 'PASS_MARKER\n' > "$fixture"

  # --expensive flag → should resolve k=5
  run python3 "$RUNNER" run expensive-test --output-file "$fixture" --expensive

  assert_success

  local row_count
  row_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM eval_runs WHERE eval_id='expensive-test';")"
  assert_equal "$row_count" "5"
}
