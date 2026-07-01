#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-response-completeness-hook.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export TEMP_DB="$HOME/cast.db"
  export CAST_DB_PATH="$TEMP_DB"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  teardown_temp_home
}

# Helper: build a SubagentStop JSON payload with a given output string
_make_input() {
  local output_text="$1"
  # Use python3 to safely encode the output text as a JSON string
  python3 -c "
import json, sys
payload = {'agent_type': 'test-agent', 'last_assistant_message': sys.argv[1]}
print(json.dumps(payload))
" "$output_text"
}

# Helper: build a SubagentStop JSON payload with a given agent_type and output string
_make_input_for_agent() {
  local agent_type="$1"
  local output_text="$2"
  python3 -c "
import json, sys
payload = {'agent_type': sys.argv[1], 'last_assistant_message': sys.argv[2]}
print(json.dumps(payload))
" "$agent_type" "$output_text"
}

# Helper: generate N lines of filler text (simulates a large files_changed array)
_filler_lines() {
  local n="$1"
  python3 -c "print('\n'.join(['  \"/path/to/file_{}.ts\"'.format(i) for i in range($n)]))"
}

@test "completeness hook: JSON status block after 50+ filler lines is NOT flagged as truncated" {
  # Simulate agent output: 50 lines of a files_changed array followed by JSON status block
  # The human-readable 'Status: DONE' line is buried before the filler, >40 lines from the end
  local filler
  filler="$(_filler_lines 50)"

  local output_text
  output_text="$(printf '%s\n\nStatus: DONE\nSummary: All done\nFiles changed: see below\n\n%s\n\n\`\`\`json status\n{\n  \"schema_version\": \"1.0\",\n  \"status\": \"DONE\",\n  \"agent\": \"code-writer\",\n  \"summary\": \"Implemented feature X\",\n  \"concerns\": [],\n  \"files_changed\": [],\n  \"next_actions\": []\n}\n\`\`\`' "$filler")"

  local input
  input="$(_make_input "$output_text")"

  # Run the hook — it should exit 0 and NOT write a completeness_events row
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # No truncation event should be recorded
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "completeness hook: Status block near top followed by 250+ Work Log lines is NOT flagged" {
  # Regression test: status block before a long Work Log section was missed when
  # the regex searched only the last 200 lines. Fix: search full output.
  local work_log_lines
  work_log_lines="$(python3 -c "print('\n'.join(['- log entry {}'.format(i) for i in range(1, 251)]))")"

  local output_text
  output_text="$(printf 'Status: DONE\nSummary: All done\nFiles changed: none\n\n## Work Log\n\n%s\n' "$work_log_lines")"

  local input
  input="$(_make_input "$output_text")"

  # Capture log line count BEFORE the run
  local log_before log_after
  log_before="$(wc -l < "$HOME/.claude/logs/hook-errors.log" 2>/dev/null || echo 0)"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # No new CAST COMPLETENESS lines should have been appended
  log_after="$(wc -l < "$HOME/.claude/logs/hook-errors.log" 2>/dev/null || echo 0)"
  local new_lines=$(( log_after - log_before ))
  assert_equal "$new_lines" "0"

  # Also confirm no completeness_events row was written
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "completeness hook: markdown-bold Status: **DONE** is NOT flagged as truncated" {
  # Regression: some agents emit Status: **DONE** (bold verb) — should NOT trigger FP
  local output_text
  output_text="$(printf 'Some work was completed.\n\nStatus: **DONE**\nSummary: All done\nFiles changed: none')"

  local input
  input="$(_make_input "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "completeness hook: truly truncated output (no Status, no JSON status) IS flagged" {
  # Simulate an agent that stopped mid-sentence — no Status block at all
  local output_text
  output_text="I am going to implement the feature now. First let me read the file and then I'll"

  local input
  input="$(_make_input "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # A truncation event should be recorded
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "1"

  # Severity should be HIGH (ends with "I'll")
  local severity
  severity="$(sqlite3 "$TEMP_DB" "SELECT severity FROM completeness_events LIMIT 1;" 2>/dev/null || echo "")"
  assert_equal "$severity" "HIGH"
}

# ---------------------------------------------------------------------------
# Status-contract exemption tests (Phase v7.5 — cast-status-contract.sh)
# ---------------------------------------------------------------------------

@test "completeness hook: exempt agent_type (general-purpose) with no Status block produces NO completeness_events row" {
  # general-purpose is a Claude Code built-in — NOT under the CAST Status contract.
  # Even with substantive prose and no Status block, no row should be written.
  local input
  input="$(_make_input_for_agent "general-purpose" "I have completed the lookup using a tool call.")"
  run bash "$HOOK_SH" <<< "$input"
  assert_success
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "completeness hook: exempt agent_type (unknown) with no Status block produces NO completeness_events row" {
  # unknown agent_type resolves when Claude Code cannot identify the subagent.
  # Must be exempt from the Status contract — no DB row written.
  local input
  input="$(_make_input_for_agent "unknown" "Some substantive prose that lacks a Status block entirely.")"
  run bash "$HOOK_SH" <<< "$input"
  assert_success
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "completeness hook: exempt agent_type (x-workflow-subagent-y) with no Status block produces NO completeness_events row" {
  # workflow-subagent substring match — exempt from the Status contract.
  local input
  input="$(_make_input_for_agent "x-workflow-subagent-y" "Structured output result from workflow step.")"
  run bash "$HOOK_SH" <<< "$input"
  assert_success
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "completeness hook: identifiable CAST agent (researcher) with prose and no Status block IS still flagged" {
  # researcher is a real CAST agent — it MUST emit a Status block.
  # This verifies we did not over-suppress: the real-truncation signal must survive.
  local input
  input="$(_make_input_for_agent "researcher" "Found several relevant sources on the topic. The analysis suggests that further investigation is needed and I will now")"
  run bash "$HOOK_SH" <<< "$input"
  assert_success
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "1"
}

@test "completeness hook: parses cleanly under /bin/bash (Bash 3.2 regression)" {
  # Regression: Bash 3.2 (macOS system shell) misparsed \'ll and \'m inside a
  # single-quoted heredoc inside $(). Verify /bin/bash exits 0 with no parser error.
  run /bin/bash "$HOOK_SH" < /dev/null
  # Should NOT emit "unexpected EOF" or "syntax error"
  refute_output --partial "unexpected EOF"
  refute_output --partial "syntax error"
  assert_success
}

# ---------------------------------------------------------------------------
# F19 regression: APPROVE and REQUEST_CHANGES must NOT be flagged as truncated
# (code-reviewer / pr-reviewer use these as terminal statuses)
# ---------------------------------------------------------------------------

@test "F19: completeness hook: Status: APPROVE is recognized as valid completion" {
  local output_text
  output_text="$(printf 'Reviewed the implementation changes carefully.\n\nThe implementation looks correct and follows project conventions.\n\nStatus: APPROVE\nSummary: Code review passed — implementation is correct.\n')"

  local input
  input="$(_make_input_for_agent "code-reviewer" "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # No completeness_events row should be written (APPROVE is a valid terminal status)
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "F19: completeness hook: Status: REQUEST_CHANGES is recognized as valid completion" {
  local output_text
  output_text="$(printf 'Reviewed the implementation changes carefully.\n\nFound issues that must be resolved before merging.\n\nStatus: REQUEST_CHANGES\nSummary: Two type safety issues found — see concerns.\nConcerns: Missing return type on parseResult()\n')"

  local input
  input="$(_make_input_for_agent "code-reviewer" "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # No completeness_events row should be written
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}
