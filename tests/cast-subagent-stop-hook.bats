#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a SubagentStop payload where last_assistant_message is the agent output.
# $1 = agent_type (default: "test-agent")
# $2 = last_assistant_message / output text (default: "")
make_stop_payload() {
  local agent_type="${1:-test-agent}"
  local output="${2:-}"
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type':             sys.argv[1],
    'session_id':             'sess-test-123',
    'stop_reason':            'end_turn',
    'last_assistant_message': sys.argv[2],
}))
" "$agent_type" "$output"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/cast/truncated-agents"
  mkdir -p "$HOME/.claude/logs"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  # Initialize cast.db so the hook's DB mirror step succeeds without error
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY,
  agent TEXT,
  session_id TEXT,
  status TEXT,
  started_at TEXT,
  ended_at TEXT,
  agent_id TEXT,
  batch_id INTEGER
);
SQL
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Truncation detection tests (Batch 4 — CAST follow-ups 2026-04-16)
#
# cast-subagent-stop-hook.sh Step 3.5 emits [CAST-TRUNCATED] when:
#   - last_assistant_message is non-empty
#   - last 40 lines do NOT contain "Status: DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT"
#
# It also writes a JSON record to ~/.claude/cast/truncated-agents/
# ---------------------------------------------------------------------------

@test "truncation detected when output has no Status block" {
  # Agent output that ends mid-sentence with no Status line
  local output
  output="$(python3 -c "
lines = ['This is agent output line ' + str(i) for i in range(30)]
lines.append('The agent was still working when it stopped unexpectedly mid-sent')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "test-agent" "$output")"
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
  # Verify a truncation record file was written
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -ge 1 ]]
}

@test "no truncation when output ends with Status: DONE" {
  local output
  output="$(python3 -c "
lines = ['Some work was completed by the agent here.'] * 5
lines.append('')
lines.append('Status: DONE')
lines.append('Summary: finished the task successfully')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "test-agent" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
}

@test "no truncation when output ends with Status: DONE_WITH_CONCERNS" {
  local output
  output="$(python3 -c "
lines = ['Agent completed work with some notes.'] * 5
lines.append('')
lines.append('Status: DONE_WITH_CONCERNS')
lines.append('Summary: completed but with warnings')
lines.append('Concerns: minor style issues noted')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "test-agent" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
}

@test "no truncation when output is empty" {
  run bash "$HOOK_SH" <<< "$(make_stop_payload "test-agent" "")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # No truncation record should be written for empty output
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "no truncation record written when agent_name is empty (unknown agent FP)" {
  # Regression: SubagentStop fired with agent_type absent/empty — CAST_STOP_AGENT resolves
  # to "unknown". Guard must skip writing a truncated-agents record in this case.
  local input
  input="$(python3 -c "
import json, sys
# agent_type missing — resolves to 'unknown' in the hook
print(json.dumps({
    'session_id':             'sess-fp-test',
    'stop_reason':            'end_turn',
    'last_assistant_message': 'Some parent-Claude conversational text with no Status block.',
}))
")"
  run bash "$HOOK_SH" <<< "$input"
  assert_success
  # No truncated-agents record should be written
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "no false positive when Status: DONE is buried under 100+ trailing lines" {
  # Reproduces long Work Log FP: Status block early, then many filler lines push it outside a 40-line window
  local output
  output="$(python3 -c "
lines = ['Status: DONE', 'Summary: all tasks complete']
lines += ['Work Log filler line ' + str(i) for i in range(100)]
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "test-agent" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "no false positive when Status verb is wrapped in markdown bold" {
  # Reproduces markdown-emphasis FP: code-reviewer ends with Status: **DONE**
  local output
  output="$(python3 -c "
lines = ['Reviewed the changes.', '', 'Status: **DONE**', 'Summary: looks good']
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-reviewer" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Workflow/Structured-Output Agent Tests (Phase 3.8.H)
#
# workflow-subagent agents emit StructuredOutput tool results, NOT prose Status blocks.
# They must NOT be subject to the truncation check (false-positive protection).
# ---------------------------------------------------------------------------

@test "workflow-subagent with no Status block is NOT flagged as truncated" {
  # Workflow subagents legitimately complete via StructuredOutput tool call
  # and do NOT emit a Status block. This must not trigger [CAST-TRUNCATED].
  local output="Tool call: structured_output({result: ...})"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "workflow-subagent" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # No truncation record should be written for workflow-subagents
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "code-writer with no Status block IS still flagged as truncated (CAST convention agents)" {
  # Code-writer is a CAST convention agent — it MUST emit a Status block.
  # Absence indicates truncation and should trigger the flag.
  local output="Applied the requested changes to the source file."
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-writer" "$output")"
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
  # Truncation record should be written for code-writer
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 1 ]]
}

@test "any agent WITH a Status block is not flagged (including workflow-subagent)" {
  # Even though workflow-subagent normally uses StructuredOutput,
  # if it does emit a Status block, no false positive is triggered.
  local output="Tool call result. Status: DONE"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "workflow-subagent" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
}

# ---------------------------------------------------------------------------
# Bug Fix Tests: False-Positive in Truncation Detection (Phase 3.8.C / v7.4.0)
#
# ISSUE: Agents dispatched inside a Workflow arrive with agent_type set to
# their actual Claude Code type (general-purpose, code-reviewer, Explore, etc.),
# NOT the literal string "workflow-subagent". The old code only exempted
# substring matches for "workflow-subagent", so healthy workflow agents
# were falsely flagged as truncated.
#
# FIX: Broadened exemption to explicitly list Claude Code built-in types:
#   general-purpose, Explore, Plan, claude, statusline-setup, output-style-setup
# These agents legitimately emit StructuredOutput or other non-CAST output
# patterns, not prose Status blocks.
# ---------------------------------------------------------------------------

@test "general-purpose agent with no Status block is NOT flagged as truncated" {
  # general-purpose is a Claude Code built-in; it emits StructuredOutput, not Status blocks.
  # This was a false-positive before the fix.
  local output="I've completed the task using a tool call."
  run bash "$HOOK_SH" <<< "$(make_stop_payload "general-purpose" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # Verify no truncation record was written
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "Explore agent with no Status block is NOT flagged as truncated" {
  # Explore is a Claude Code built-in search/navigation tool; it doesn't emit CAST Status blocks.
  local output="Found relevant files: src/foo.js, tests/foo.test.js"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "Explore" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # Verify no truncation record was written
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "Plan agent with no Status block is NOT flagged as truncated" {
  # Plan is a Claude Code built-in planning tool.
  local output="Here is my plan: 1) Review code 2) Make changes 3) Run tests"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "Plan" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # Verify no truncation record was written
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "REGRESSION: code-writer with no Status block IS still flagged as truncated" {
  # CRITICAL: code-writer is a CAST convention agent — it MUST emit a Status block.
  # This test ensures the fix didn't accidentally exempt CAST agents.
  # (This test already exists above but we emphasize it as a regression guard.)
  local output="Applied the requested changes to the source file."
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-writer" "$output")"
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
  # Verify truncation record WAS written for code-writer
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 1 ]]
}

@test "code-writer with valid Status block is not flagged (sanity check)" {
  # Verify normal operation: code-writer WITH Status block → no truncation flag.
  local output="Applied the requested changes.

Status: DONE
Summary: task completed successfully"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-writer" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # No truncation record
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "researcher (real CAST agent) with no Status block IS flagged" {
  # researcher is a real CAST agent (not exempt). It must emit a Status block.
  # This verifies that the exemption list is limited to non-CAST built-ins.
  local output="Found interesting article on the topic. Will summarize in next message."
  run bash "$HOOK_SH" <<< "$(make_stop_payload "researcher" "$output")"
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
  # Verify truncation record was written
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Status-contract exemption tests (Phase v7.5 — cast-status-contract.sh)
#
# Agents with agent_type "unknown" are NOT under the CAST Status contract.
# They must NOT emit [CAST-TRUNCATED] even with substantive prose + no Status block.
# Identifiable CAST agents (code-writer, researcher) remain under contract.
# ---------------------------------------------------------------------------

@test "unknown agent_type with no Status block does NOT emit [CAST-TRUNCATED] banner" {
  # agent_type "unknown" fires when Claude Code cannot identify the subagent.
  # These are not bound by the CAST protocol — suppress the banner.
  local output="This is some substantive prose output without a Status block at all."
  run bash "$HOOK_SH" <<< "$(make_stop_payload "unknown" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # No truncation record should be written
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "code-writer agent_type with prose + no Status block STILL emits [CAST-TRUNCATED] banner" {
  # Identifiable CAST agents remain under contract after the unknown-exemption fix.
  # A real truncation for code-writer must still surface.
  local output="I am applying the changes to the file now. Let me read it first and then I will"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-writer" "$output")"
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
}
