#!/usr/bin/env bats
# cast-record-review.bats — Tests for scripts/cast-record-review.py (B5 record-review loop)
#
# Isolation: uses setup_temp_home/teardown_temp_home (HOME redirected to tmp).
# DB:        cast-db-init.sh provisions the canonical schema per test.
# Live-probe: test (1)/(2) read from a COPY of the real ~/.claude/cast.db when present
#             (skip gracefully otherwise) — per the live-probe-over-synthetic-fixtures rule.
#
# Coverage:
#   (1) live-probe acceptance   — real db copy -> exit 0, report file, >=3 "### Proposal"
#   (2) read-only integrity     — md5sum of db copy unchanged after the run
#   (3) empty-db honesty        — fresh empty db -> all 4 section headers, explicit "no findings"
#   (4) section 2 dedup         — existing eval case -> "existing case", no new yaml block
#   (5) section 3 friction      — confirmed vs proactive classification
#   (6) section 4 silent-producer honesty — hook_failures 0 rows reported explicitly

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-record-review.py"
AGENTS_DIR="$REPO_DIR/agents/core"
EVALS_DIR="$REPO_DIR/evals/cases"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs" "$HOME/.claude/projects"
  export TEST_DB="$HOME/cast-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  export OUT_DIR="$HOME/reports-out"
  mkdir -p "$OUT_DIR"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

init_db() {
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

# Run the script, stdout only (the report path), stderr suppressed.
run_record_review() {
  run bash -c "python3 '$SCRIPT' --db '$TEST_DB' --out-dir '$OUT_DIR' \
    --agents-dir '$AGENTS_DIR' --evals-dir '$EVALS_DIR' \
    --audit-log '$HOME/.claude/logs/audit.jsonl' --projects-dir '$HOME/.claude/projects/' \
    2>/dev/null"
}

# Run merging stderr into $output — for debugging failed runs.
run_record_review_debug() {
  run bash -c "python3 '$SCRIPT' --db '$TEST_DB' --out-dir '$OUT_DIR' \
    --agents-dir '$AGENTS_DIR' --evals-dir '$EVALS_DIR' \
    --audit-log '$HOME/.claude/logs/audit.jsonl' --projects-dir '$HOME/.claude/projects/' \
    2>&1"
}

report_path_from_output() {
  printf '%s' "$output" | tail -1
}

# ---------------------------------------------------------------------------
# (1) Live-probe acceptance
# ---------------------------------------------------------------------------

@test "(1) live-probe: real cast.db copy -> exit 0, report file, >=3 proposals" {
  [[ -f "$ORIG_HOME/.claude/cast.db" ]] || skip "no real cast.db found at $ORIG_HOME/.claude/cast.db"

  cp "$ORIG_HOME/.claude/cast.db" "$TEST_DB"

  run_record_review_debug
  assert_success

  local report_path; report_path="$(report_path_from_output)"
  [[ -f "$report_path" ]] || {
    echo "FAIL: report file not found at '$report_path'" >&2
    echo "Full output: $output" >&2
    return 1
  }

  local count; count="$(grep -c '^### Proposal:' "$report_path")"
  [ "$count" -ge 3 ]
}

# ---------------------------------------------------------------------------
# (2) Read-only integrity — db copy unchanged after the run
# ---------------------------------------------------------------------------

@test "(2) read-only integrity: db copy md5 unchanged after run" {
  [[ -f "$ORIG_HOME/.claude/cast.db" ]] || skip "no real cast.db found at $ORIG_HOME/.claude/cast.db"

  cp "$ORIG_HOME/.claude/cast.db" "$TEST_DB"
  local before; before="$(md5sum "$TEST_DB" | awk '{print $1}')"

  run_record_review
  assert_success

  local after; after="$(md5sum "$TEST_DB" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# (3) Empty-db honesty
# ---------------------------------------------------------------------------

@test "(3) empty db: exit 0, all 4 section headers present with explicit no-findings lines" {
  init_db
  run_record_review_debug
  assert_success

  local report_path; report_path="$(report_path_from_output)"
  [[ -f "$report_path" ]]

  run cat "$report_path"
  assert_output --partial "## 1. Measure→Tune"
  assert_output --partial "## 2. Mine→Propose"
  assert_output --partial "## 3. Friction Mining"
  assert_output --partial "## 4. Trend→Alert"
  assert_output --partial "No findings this window"
  assert_output --partial "No quality_gates rows"
}

# ---------------------------------------------------------------------------
# (4) Section 2 dedup — existing eval case short-circuits new-case drafting
# ---------------------------------------------------------------------------

@test "(4) section 2 dedup: existing code-writer/file_write eval case -> 'existing case', no new yaml block" {
  [[ -f "$EVALS_DIR/code-writer/hallucination-claimed-file-write.yaml" ]] || \
    skip "expected eval case evals/cases/code-writer/hallucination-claimed-file-write.yaml not found"

  init_db
  # Insert 5 rows to cross the n>=5 threshold documented in section_mine_propose().
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  for i in 1 2 3 4 5; do
    sqlite3 "$TEST_DB" \
      "INSERT INTO agent_hallucinations (session_id, agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
       VALUES ('sess-$i', 'code-writer', 'file_write', 'claimed.py', 'not written', 0, '$now');"
  done

  run_record_review_debug
  assert_success

  local report_path; report_path="$(report_path_from_output)"
  run cat "$report_path"
  assert_output --partial "existing case"
  refute_output --partial '```yaml'
}

# ---------------------------------------------------------------------------
# (5) Section 3 friction classification — confirmed vs proactive
# ---------------------------------------------------------------------------

@test "(5) section 3: hatch with preceding block text is confirmed, without is proactive" {
  init_db
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  # session-confirmed: transcript has the block substring BEFORE the hatch timestamp.
  mkdir -p "$HOME/.claude/projects/testproj"
  printf '%s\n' '{"role":"assistant","text":"**[CAST]** Raw `git commit` blocked. Dispatch the `commit` agent instead."}' \
    > "$HOME/.claude/projects/testproj/session-confirmed-abc.jsonl"

  # session-proactive: transcript has no block substrings at all.
  printf '%s\n' '{"role":"assistant","text":"Everything looks fine, proceeding."}' \
    > "$HOME/.claude/projects/testproj/session-proactive-xyz.jsonl"

  cat > "$HOME/.claude/logs/audit.jsonl" <<EOF
{"timestamp":"$now","event":"COMMIT_HATCH_USED","override_env":"CAST_COMMIT_AGENT","git_op":"commit","repo":"$REPO_DIR","session_id":"confirmed-abc","in_claude_session":true}
{"timestamp":"$now","event":"COMMIT_HATCH_USED","override_env":"CAST_COMMIT_AGENT","git_op":"commit","repo":"$REPO_DIR","session_id":"proactive-xyz","in_claude_session":true}
EOF

  run_record_review_debug
  assert_success

  local report_path; report_path="$(report_path_from_output)"
  run cat "$report_path"
  assert_output --partial "2 hatch/override events"
  assert_output --partial "1 confirmed friction, 1 proactive"
}

# ---------------------------------------------------------------------------
# (6) Section 4 silent-producer honesty — hook_failures 0 rows reported explicitly
# ---------------------------------------------------------------------------

@test "(6) section 4: hook_failures with 0 rows is an explicit INFO finding, not omitted" {
  init_db
  run_record_review_debug
  assert_success

  local report_path; report_path="$(report_path_from_output)"
  run cat "$report_path"
  assert_output --partial "hook_failures has 0 rows in this window"
  assert_output --partial "documented"
}
