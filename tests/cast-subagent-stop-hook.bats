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

# Helper: make a SubagentStop payload with optional batch_id
make_handoff_payload() {
  local agent_type="${1:-test-agent}"
  local output="${2:-}"
  local batch_id="${3:-}"
  python3 -c "
import json, sys
payload = {
    'agent_type':             sys.argv[1],
    'session_id':             'sess-test-handoff',
    'stop_reason':            'end_turn',
    'last_assistant_message': sys.argv[2],
}
if sys.argv[3]:
    payload['batch_id'] = sys.argv[3]
print(json.dumps(payload))
" "$agent_type" "$output" "$batch_id"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
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
  duration_ms INTEGER,
  tool_uses INTEGER,
  response TEXT,
  cost_usd REAL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  model TEXT,
  cache_read_input_tokens INTEGER,
  cache_creation_input_tokens INTEGER
);
SQL
  unset CLAUDE_SUBPROCESS
}

teardown() {
  teardown_temp_home
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
# Three-value truncation classifier tests (Phase 14 — TRUNC_CLASS 0/1/2)
#
# TRUNC_CLASS=0: well-formed (Status block present)            → no action
# TRUNC_CLASS=1: missing_formality (>=200 chars, clean ending) → suppress banner, write protocol-violation
# TRUNC_CLASS=2: actual_truncation (structural signals)        → fire [CAST-TRUNCATED] banner
# ---------------------------------------------------------------------------

@test "missing formality — clean long output without Status block suppresses banner" {
  # TRUNC_CLASS=1: >=200 chars, ends with period, no Status block.
  # push-agent "The push succeeded." class must NOT fire [CAST-TRUNCATED].
  local output
  output="$(python3 -c "
lines = ['The push to origin main completed successfully. All checks passed.'] * 6
lines.append('The branch is now fully up to date with the remote repository.')
print('\n'.join(lines))
")"
  # Wire agent_protocol_violations so we can verify the row is written
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL
  run bash "$HOOK_SH" <<< "$(make_stop_payload "push" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  # No truncation file written (banner suppressed for missing formality)
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
  # Protocol violation row IS written for observability
  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='missing_formality';")"
  [[ "$rows" -ge 1 ]]
}

@test "actual truncation — trailing colon fires [CAST-TRUNCATED] banner" {
  # TRUNC_CLASS=2 via signal 2: long output (>=200 chars) ending with ":"
  # Classic "Now I'll run the tests:" pattern — clearly truncated mid-step.
  local output
  output="$(python3 -c "
lines = ['Starting analysis of the codebase to identify potential issues.'] * 4
lines.append('Now running the following validation checks to verify correctness:')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-writer" "$output")"
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -ge 1 ]]
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

# ---------------------------------------------------------------------------
# Regression: Bug 1 — recursive glob finds workflow-nested transcripts
# (was: flat glob returned 0 matches for workflow/orchestrator-dispatched agents)
# ---------------------------------------------------------------------------

@test "transcript glob: flat path still resolves (non-recursive path unbroken)" {
  # Create a flat transcript at the traditional location
  local session_dir="$HOME/.claude/projects/proj/${BATS_TEST_NUMBER}-sess"
  mkdir -p "$session_dir/subagents"
  local agent_id="agent-flat-regression-001"
  local transcript="$session_dir/subagents/agent-${agent_id}.jsonl"
  echo '{}' > "$transcript"

  result="$(CAST_STOP_AGENT_ID="$agent_id" CAST_STOP_SESSION="${BATS_TEST_NUMBER}-sess" python3 -c "
import glob, os, sys
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
session_id = os.environ.get('CAST_STOP_SESSION', '')
if not agent_id or not session_id:
    sys.exit(1)
pattern = os.path.expanduser(f'~/.claude/projects/*/{session_id}/subagents/**/agent-{agent_id}.jsonl')
matches = glob.glob(pattern, recursive=True)
if matches:
    print(max(matches, key=os.path.getmtime))
")"
  [[ "$result" == "$transcript" ]]
}

@test "transcript glob: workflow-nested path resolves with recursive=True (Bug 1 fix)" {
  # Create a workflow-nested transcript (the path that previously returned 0 matches)
  local session_id="wf-regression-sess-${BATS_TEST_NUMBER}"
  local agent_id="agent-wf-regression-${BATS_TEST_NUMBER}"
  local nested_dir="$HOME/.claude/projects/proj/$session_id/subagents/workflows/wf_abc123def"
  mkdir -p "$nested_dir"
  local transcript="$nested_dir/agent-${agent_id}.jsonl"
  echo '{}' > "$transcript"

  # OLD pattern (non-recursive) — must return 0 matches
  old_count="$(CAST_STOP_AGENT_ID="$agent_id" CAST_STOP_SESSION="$session_id" python3 -c "
import glob, os
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
session_id = os.environ.get('CAST_STOP_SESSION', '')
pattern = os.path.expanduser(f'~/.claude/projects/*/{session_id}/subagents/agent-{agent_id}.jsonl')
print(len(glob.glob(pattern)))
")"
  [[ "$old_count" -eq 0 ]]

  # NEW pattern (recursive) — must return 1 match
  new_result="$(CAST_STOP_AGENT_ID="$agent_id" CAST_STOP_SESSION="$session_id" python3 -c "
import glob, os
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
session_id = os.environ.get('CAST_STOP_SESSION', '')
pattern = os.path.expanduser(f'~/.claude/projects/*/{session_id}/subagents/**/agent-{agent_id}.jsonl')
matches = glob.glob(pattern, recursive=True)
if matches:
    print(max(matches, key=os.path.getmtime))
")"
  [[ "$new_result" == "$transcript" ]]
}

# ---------------------------------------------------------------------------
# Bug Fix Tests: fan-out sibling clobber (BUG 1) and duration_ms from timestamps (BUG 2)
# ---------------------------------------------------------------------------

@test "BUG1: only ONE running row is closed when two rows share the same agent_id" {
  # Insert two running rows with the same agent_id — simulates parallel fan-out
  local shared_agent_id="shared-agent-fanout-001"
  sqlite3 "$CAST_DB_PATH" <<SQL
INSERT INTO agent_runs (agent, session_id, status, started_at, ended_at, agent_id)
VALUES ('code-writer', 'sess-fanout', 'running', '2026-01-01T10:00:00Z', NULL, '${shared_agent_id}');
INSERT INTO agent_runs (agent, session_id, status, started_at, ended_at, agent_id)
VALUES ('code-writer', 'sess-fanout', 'running', '2026-01-01T10:01:00Z', NULL, '${shared_agent_id}');
SQL

  # Verify we have 2 running rows with that agent_id before the hook fires
  local before
  before="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE status='running' AND agent_id='${shared_agent_id}'")"
  [[ "$before" -eq 2 ]]

  # Fire the hook with a stop payload carrying that agent_id
  local payload
  payload="$(python3 -c "
import json, sys
print(json.dumps({
    'agent_type': 'code-writer',
    'agent_id':   sys.argv[1],
    'session_id': 'sess-fanout',
    'stop_reason': 'end_turn',
    'last_assistant_message': 'Status: DONE\nSummary: done',
}))
" "$shared_agent_id")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # Exactly ONE row should now be DONE — the other must stay running
  local done_count running_count
  done_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE status='DONE' AND agent_id='${shared_agent_id}'")"
  running_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE status='running' AND agent_id='${shared_agent_id}'")"
  [[ "$done_count" -eq 1 ]]
  [[ "$running_count" -eq 1 ]]
}

@test "BUG2: duration_ms is computed > 0 from started_at/ended_at timestamps" {
  # Insert a running row with a known started_at; the hook sets ended_at=now and
  # computes duration_ms = julianday(ended_at) - julianday(started_at) in ms.
  local agent_id="duration-test-agent-001"
  # started_at 60 seconds in the past
  local started_at
  started_at="$(python3 -c "
from datetime import datetime, timezone, timedelta
t = datetime.now(timezone.utc) - timedelta(seconds=60)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

  sqlite3 "$CAST_DB_PATH" <<SQL
INSERT INTO agent_runs (agent, session_id, status, started_at, ended_at, agent_id)
VALUES ('code-writer', 'sess-dur', 'running', '${started_at}', NULL, '${agent_id}');
SQL

  local payload
  payload="$(python3 -c "
import json, sys
print(json.dumps({
    'agent_type':  'code-writer',
    'agent_id':    sys.argv[1],
    'session_id':  'sess-dur',
    'stop_reason': 'end_turn',
    'last_assistant_message': 'Status: DONE\nSummary: done',
}))
" "$agent_id")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # duration_ms must be > 0 (computed from timestamps, not from payload which is always 0)
  local duration_ms
  duration_ms="$(sqlite3 "$CAST_DB_PATH" "SELECT duration_ms FROM agent_runs WHERE agent_id='${agent_id}' LIMIT 1")"
  [[ -n "$duration_ms" ]]
  [[ "$duration_ms" -gt 0 ]]
}

@test "transcript glob: tiebreak selects newest by mtime when multiple matches exist" {
  local session_id="mtime-sess-${BATS_TEST_NUMBER}"
  local agent_id="agent-mtime-${BATS_TEST_NUMBER}"

  # Create two matches — flat and nested
  local flat_dir="$HOME/.claude/projects/proj/$session_id/subagents"
  local nested_dir="$HOME/.claude/projects/proj/$session_id/subagents/workflows/wf_xyz"
  mkdir -p "$flat_dir" "$nested_dir"

  local flat_transcript="$flat_dir/agent-${agent_id}.jsonl"
  local nested_transcript="$nested_dir/agent-${agent_id}.jsonl"

  # Write flat first, then nested (nested is newer)
  echo '{}' > "$flat_transcript"
  sleep 0.05
  echo '{}' > "$nested_transcript"

  result="$(CAST_STOP_AGENT_ID="$agent_id" CAST_STOP_SESSION="$session_id" python3 -c "
import glob, os
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
session_id = os.environ.get('CAST_STOP_SESSION', '')
pattern = os.path.expanduser(f'~/.claude/projects/*/{session_id}/subagents/**/agent-{agent_id}.jsonl')
matches = glob.glob(pattern, recursive=True)
if matches:
    print(max(matches, key=os.path.getmtime))
")"
  # Should pick the newest (nested)
  [[ "$result" == "$nested_transcript" ]]
}

# ---------------------------------------------------------------------------
# F19 regression: APPROVE and REQUEST_CHANGES must NOT produce missing_formality
# (corpus failure F19 — code-reviewer/pr-reviewer reviewer statuses were false-flagged)
# ---------------------------------------------------------------------------

@test "F19: code-reviewer Status: APPROVE does NOT produce missing_formality violation" {
  # Wire agent_protocol_violations table
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Reviewed the implementation changes carefully.'] * 6
lines.append('')
lines.append('The implementation looks correct. No issues found.')
lines.append('')
lines.append('Status: APPROVE')
lines.append('Summary: Code review passed — changes are correct and well-structured.')
print('\n'.join(lines))
")"

  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-reviewer" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"

  # No missing_formality violation should be written
  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='missing_formality';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "F19: code-reviewer Status: REQUEST_CHANGES does NOT produce missing_formality violation" {
  # Wire agent_protocol_violations table
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Reviewed the implementation changes carefully.'] * 6
lines.append('')
lines.append('Found issues that must be resolved before merging.')
lines.append('')
lines.append('Status: REQUEST_CHANGES')
lines.append('Summary: Two type safety issues found — see concerns.')
lines.append('Concerns: Missing return type annotation on parseResult(), unused import in utils.ts')
print('\n'.join(lines))
")"

  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-reviewer" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"

  # No missing_formality violation should be written
  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='missing_formality';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Handoff Block Validation Tests (Step 2.4 — CAST v8)
#
# Validates the typed ## Handoff schema in chained agent responses.
# Required fields: files_changed, status (DONE|DONE_WITH_CONCERNS|BLOCKED), blockers
# Exemptions: agents in STATUS_CONTRACT_EXEMPT (Claude Code built-ins) are skipped.
# False-positive guard: absent block + no batch_id → log NOTHING (solo dispatch)
#
# Writer: cast-subagent-stop-hook.sh Step 2.4
# Target table: agent_protocol_violations (violation column)
# ---------------------------------------------------------------------------

@test "Handoff: valid block present + chained agent → NO violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['The task has been completed successfully.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/foo.js, src/bar.js')
lines.append('status: DONE')
lines.append('blockers: none')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "test-writer" "$output" "batch-001")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "Handoff: malformed block → invalid_handoff_format violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['The task is complete.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('this is complete garbage')
lines.append('no actual structure here')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "test-writer" "$output" "batch-002")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='invalid_handoff_format';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 1 ]]
}

@test "Handoff: missing required field (status) → handoff_schema_violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['The task is complete.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/foo.js')
lines.append('blockers: none')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "test-writer" "$output" "batch-003")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='handoff_schema_violation' AND pattern='missing_field:status';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 1 ]]
}

@test "Handoff: invalid status enum value → handoff_schema_violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Task finished.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/foo.js')
lines.append('status: INVALID_STATUS')
lines.append('blockers: none')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "test-writer" "$output" "batch-005")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='handoff_schema_violation' AND pattern LIKE 'invalid_value:status=%';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 1 ]]
}

@test "Handoff: absent block + chained (batch_id) → missing_handoff violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output="The work is complete but no Handoff block present."

  local payload
  payload="$(make_handoff_payload "test-writer" "$output" "batch-006")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='missing_handoff';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 1 ]]
}

@test "Handoff: absent block + solo (no batch_id) → NO violation (critical false-positive guard)" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output="The task is complete but no Handoff block here."

  local payload
  payload="$(make_handoff_payload "test-writer" "$output")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "Handoff: exempt agent (general-purpose) chained without block → NO violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output="Tool call result data. No Status block."

  local payload
  payload="$(make_handoff_payload "general-purpose" "$output" "batch-007")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "Handoff: CAST agent valid block with all required fields → NO violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Completed the code review.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/index.ts, tests/index.test.ts')
lines.append('status: DONE_WITH_CONCERNS')
lines.append('blockers: Minor style issue on line 42')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "code-reviewer" "$output" "batch-008")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Unit tests for cast_handoff_parser.py CLI
# ---------------------------------------------------------------------------

@test "cast_handoff_parser.py: valid block → ok=true" {
  local input
  input="$(python3 -c "
text = '''Some work done.

## Handoff
files_changed: src/main.py, src/utils.py
status: DONE
blockers: none
'''
print(text)
")"

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_success
  assert_output --partial '"ok": true'
  assert_output --partial '"violation": null'
}

@test "cast_handoff_parser.py: missing field → violation=handoff_schema_violation" {
  local input="$(python3 -c "
text = '''Work complete.

## Handoff
files_changed: src/main.py
blockers: none
'''
print(text)
")"

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_failure
  assert_output --partial '"violation": "handoff_schema_violation"'
  assert_output --partial '"pattern": "missing_field:status"'
}

@test "cast_handoff_parser.py: invalid status enum → violation=handoff_schema_violation" {
  local input="$(python3 -c "
text = '''Done.

## Handoff
files_changed: src/main.py
status: BAD_STATUS
blockers: none
'''
print(text)
")"

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_failure
  assert_output --partial '"violation": "handoff_schema_violation"'
  assert_output --partial '"pattern": "invalid_value:status=BAD_STATUS"'
}

@test "cast_handoff_parser.py: no Handoff block → violation=missing_handoff" {
  local input="Work completed without Handoff block."

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_failure
  assert_output --partial '"violation": "missing_handoff"'
}

@test "cast_handoff_parser.py: malformed block (garbage lines) → violation=invalid_handoff_format" {
  local input="$(python3 -c "
text = '''Done.

## Handoff
completely unstructured junk here
no colons or proper structure here
'''
print(text)
")"

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_failure
  assert_output --partial '"violation": "invalid_handoff_format"'
}

# ---------------------------------------------------------------------------
# Additional Handoff Validation Cases (Comprehensive Coverage)
# ---------------------------------------------------------------------------

@test "Handoff: missing files_changed field → handoff_schema_violation with pattern" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Work completed.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('status: DONE')
lines.append('blockers: none')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "code-writer" "$output" "batch-fc1")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='handoff_schema_violation' AND pattern='missing_field:files_changed';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 1 ]]
}

@test "Handoff: missing blockers field → handoff_schema_violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Work finished.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/app.py')
lines.append('status: BLOCKED')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "debugger" "$output" "batch-fc2")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='handoff_schema_violation' AND pattern='missing_field:blockers';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 1 ]]
}

@test "Handoff: empty files_changed value → handoff_schema_violation (empty_field)" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Complete.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed:')
lines.append('status: DONE')
lines.append('blockers: none')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "code-writer" "$output" "batch-fc3")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations WHERE violation='handoff_schema_violation' AND pattern='empty_field:files_changed';" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 1 ]]
}

@test "Handoff: status with extra whitespace is trimmed and validated correctly" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Work done.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/main.py')
lines.append('status:   DONE_WITH_CONCERNS  ')
lines.append('blockers: minor inconsistency')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "code-reviewer" "$output" "batch-fc4")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "Handoff: chained agent with NO response text → gracefully skip validation (response_text empty)" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'test-writer',
    'session_id': 'sess-empty',
    'stop_reason': 'end_turn',
    'batch_id': 'batch-fc5',
    'last_assistant_message': '',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "Handoff: solo agent (no batch_id, absent block) correctly exits without logging" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  # Make a payload with NO batch_id (solo dispatch), no Handoff block
  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'researcher',
    'session_id': 'sess-solo-123',
    'stop_reason': 'end_turn',
    'last_assistant_message': 'Task completed. This is solo dispatch without a Handoff block and no batch_id.',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # CRITICAL: Zero violations logged (false-positive guard)
  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "Handoff: solo agent with valid block (nice-to-have, not required) → NO violation" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = ['Task complete.'] * 5
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/analysis.py')
lines.append('status: DONE')
lines.append('blockers: none')
print('\n'.join(lines))
")"

  # No batch_id — solo dispatch
  local payload
  payload="$(python3 -c "
import json, sys
print(json.dumps({
    'agent_type': 'researcher',
    'session_id': 'sess-solo-456',
    'stop_reason': 'end_turn',
    'last_assistant_message': '''$output''',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # No violations (solo dispatch is not required to have Handoff)
  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "Handoff: batch_id null vs absent — both treated as solo (guard for variant payloads)" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  # Payload with batch_id: null (JSON null, not absent)
  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'test-writer',
    'session_id': 'sess-null-batch',
    'stop_reason': 'end_turn',
    'batch_id': None,
    'last_assistant_message': 'Work done without Handoff block.',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # Should NOT log missing_handoff (null batch_id treated as solo)
  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

@test "cast_handoff_parser.py: empty file content → violation=missing_handoff" {
  local input=""

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_failure
  assert_output --partial '"violation": "missing_handoff"'
}

@test "cast_handoff_parser.py: block with extra optional fields (not validated) → ok=true" {
  local input
  input="$(python3 -c "
text = '''Work complete.

## Handoff
files_changed: src/main.py
status: DONE
blockers: none
agent: my-agent
key_decisions: used approach X
next_agent_needs: stage-gate approval
extra_field: allowed as-is
'''
print(text)
")"

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_success
  assert_output --partial '"ok": true'
}

@test "cast_handoff_parser.py: status enum case-sensitive validation" {
  # "done" (lowercase) should fail — enum values are uppercase
  local input
  input="$(python3 -c "
text = '''Done.

## Handoff
files_changed: src/main.py
status: done
blockers: none
'''
print(text)
")"

  run python3 scripts/cast_handoff_parser.py <<< "$input"
  assert_failure
  assert_output --partial '"violation": "handoff_schema_violation"'
  assert_output --partial '"pattern": "invalid_value:status=done"'
}

@test "Handoff: complex real-world block with multi-line values parses correctly" {
  sqlite3 "$CAST_DB_PATH" <<'TBSQL'
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  agent_type TEXT NOT NULL,
  agent_id TEXT,
  batch_id INTEGER,
  violation TEXT NOT NULL,
  pattern TEXT,
  timestamp TEXT NOT NULL,
  raw_excerpt TEXT
);
TBSQL

  local output
  output="$(python3 -c "
lines = []
lines.append('Task completed after multiple iterations.')
lines.append('')
lines.append('Status: DONE_WITH_CONCERNS')
lines.append('Summary: Completed with minor concerns.')
lines.append('')
lines.append('## Handoff')
lines.append('files_changed: src/index.ts, src/components/Button.tsx, tests/button.test.ts')
lines.append('status: DONE_WITH_CONCERNS')
lines.append('blockers: TypeScript strict mode warnings in ButtonComponent: expected to fix in PR review')
lines.append('key_decisions: Used React.FC pattern for consistency with codebase')
lines.append('agent: code-writer')
print('\n'.join(lines))
")"

  local payload
  payload="$(make_handoff_payload "code-writer" "$output" "batch-complex")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # Valid block with multi-line values → no violations
  local rows
  rows="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_protocol_violations;" 2>/dev/null || echo 0)"
  [[ "$rows" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# U12: Verdict-keyword exemption (short output with known CAST keyword is well-formed)
# ---------------------------------------------------------------------------

@test "U12: short bare verdict output is NOT flagged as truncated (VERDICT: APPROVE)" {
  # A code-reviewer legitimately ends with a bare short verdict such as "VERDICT: APPROVE".
  # The verdict-keyword exemption must classify this as well-formed (no [CAST-TRUNCATED]).
  local output="VERDICT: APPROVE"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-reviewer" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "U12: short mid-sentence output WITHOUT verdict keyword IS still flagged as truncated" {
  # A genuinely truncated output (mid-sentence, no verdict keyword) must still fire the banner.
  # Signal 1 (<200 chars) must not be weakened by the exemption.
  local output="Now let me run the tests:"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-writer" "$output")"
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# F2 Step 2b: dispatch_decisions OUTCOME-UPDATE (v9 F2 record→decision loop)
#
# The SubagentStop hook resolves a pending dispatch_decisions row to DONE or
# BLOCKED when the agent stops.  FIFO MIN(id) match on session_id+chosen_agent.
# No matching row → no-op (hook still exits 0, unrelated rows untouched).
# ---------------------------------------------------------------------------

@test "F2 Step2b: pending dispatch_decisions row resolves to DONE on task_completed" {
  # Wire the dispatch_decisions table (minimal schema matching the real db-init shape).
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS dispatch_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  prompt_snippet TEXT,
  chosen_agent TEXT,
  outcome TEXT
);
SQL

  # Pre-insert the pending row that a PreToolUse(Task) hook would have written.
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO dispatch_decisions (session_id, prompt_snippet, chosen_agent, outcome) \
     VALUES ('s-dd', 'fix X', 'debugger', 'pending')"

  # Build a payload with matching agent_type + session_id and a Status: DONE response.
  local output="Investigated the failure and applied the fix.

Status: DONE
Summary: root cause found and resolved"
  local payload
  payload="$(python3 -c "
import json, sys
print(json.dumps({
    'agent_type':             'debugger',
    'session_id':             's-dd',
    'stop_reason':            'end_turn',
    'last_assistant_message': sys.argv[1],
}))
" "$output")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # The pending row must now be 'DONE'.
  local resolved
  resolved="$(sqlite3 "$CAST_DB_PATH" \
    "SELECT outcome FROM dispatch_decisions WHERE session_id='s-dd' AND chosen_agent='debugger' LIMIT 1")"
  [[ "$resolved" = "DONE" ]]
}

@test "F2 Step2b: no matching pending row → hook exits 0, unrelated row stays pending" {
  # Wire the dispatch_decisions table.
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS dispatch_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  prompt_snippet TEXT,
  chosen_agent TEXT,
  outcome TEXT
);
SQL

  # Insert a pending row for a DIFFERENT session/agent — must remain untouched.
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO dispatch_decisions (session_id, prompt_snippet, chosen_agent, outcome) \
     VALUES ('s-unrelated', 'other task', 'researcher', 'pending')"

  # Fire hook with a session+agent that has NO matching pending row.
  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'agent_type':             'code-writer',
    'session_id':             's-nomatch',
    'stop_reason':            'end_turn',
    'last_assistant_message': 'Status: DONE\nSummary: done',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # The unrelated row must still be 'pending'.
  local still_pending
  still_pending="$(sqlite3 "$CAST_DB_PATH" \
    "SELECT outcome FROM dispatch_decisions WHERE session_id='s-unrelated' AND chosen_agent='researcher' LIMIT 1")"
  [[ "$still_pending" = "pending" ]]
}

# ---------------------------------------------------------------------------
# Security: eval injection protection (cast-subagent-stop-hook.sh line 215)
# ---------------------------------------------------------------------------

@test "eval injection: backticks in agent_name does NOT execute" {
  # The hook uses `eval` on shlex-quoted fields. This test verifies that
  # malicious input (backticks in agent output) does NOT execute.
  # shlex.quote() must protect against command injection.

  # Create a marker file path inside the temp HOME to track injection attempts
  local marker="$HOME/.cast-test-injection-marker-$$"

  # Payload with backticks in agent_type (which becomes AGENT_NAME after eval)
  local payload
  payload="$(python3 -c "
import json
# Attempt injection via agent_type: backticks that would execute 'touch' if not quoted
print(json.dumps({
    'agent_type':             'test-\`touch ${marker}\`',
    'session_id':             'sess-inject-test',
    'stop_reason':            'end_turn',
    'last_assistant_message': 'Status: DONE',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"

  # Hook must exit 0 (never blocks)
  assert_success

  # Marker file must NOT exist (injection was blocked by shlex.quote)
  [ ! -f "$marker" ]

  # Cleanup
  rm -f "$marker"
}

@test "eval injection: dollar-paren in output does NOT execute" {
  # Injection attempt via $(...) syntax in agent output
  local marker="$HOME/.cast-test-injection-marker-$$"

  local payload
  payload="$(python3 -c "
import json
# Attempt injection via output: \$(...) that would touch marker if not quoted
print(json.dumps({
    'agent_type':             'test-agent',
    'session_id':             'sess-inject-test-2',
    'stop_reason':            'end_turn',
    'last_assistant_message': 'Status: DONE\n\$(touch ${marker})',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"

  assert_success

  # Marker file must NOT exist
  [ ! -f "$marker" ]

  rm -f "$marker"
}

@test "eval injection: semicolon-command in stop_reason does NOT execute" {
  # Injection attempt via stop_reason field: ; touch marker
  local marker="$HOME/.cast-test-injection-marker-$$"

  local payload
  payload="$(python3 -c "
import json
# Attempt injection via stop_reason
print(json.dumps({
    'agent_type':             'test-agent',
    'session_id':             'sess-inject-test-3',
    'stop_reason':            'end_turn; touch ${marker}',
    'last_assistant_message': 'Status: DONE',
}))
")"

  run bash "$HOOK_SH" <<< "$payload"

  assert_success

  # Marker file must NOT exist
  [ ! -f "$marker" ]

  rm -f "$marker"
}

# ---------------------------------------------------------------------------
# LF-8: markdown-bold Status regression tests
#
# Bug (a): DONE|DONE_WITH_CONCERNS alternation matches "DONE" prefix of
#          "DONE_WITH_CONCERNS", causing WITH_CONCERNS agents to be recorded
#          as plain DONE.
# Bug (b): Status:\s*(\S+) captures trailing ** (e.g. "DONE**").
#
# Both bugs are fixed in every Status-value regex in the hook. These tests
# verify the two live-observed failure cases.
# ---------------------------------------------------------------------------

@test "LF-8(a): **Status: DONE_WITH_CONCERNS** is recognized as DONE_WITH_CONCERNS (not DONE)" {
  # Regression: DONE|DONE_WITH_CONCERNS alternation short-circuits to DONE.
  # After the fix the hook must treat this as well-formed (not truncated).
  local output
  output="$(python3 -c "
lines = ['Reviewed changes and found minor concerns.'] * 5
lines.append('')
lines.append('**Status: DONE_WITH_CONCERNS**')
lines.append('Summary: review complete with concerns')
lines.append('Concerns: one minor type annotation missing')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-reviewer" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

@test "LF-8(b): Status: DONE** (trailing bold) is recognized as well-formed" {
  # Regression: Status:\s*(\S+) captures "DONE**" including trailing emphasis.
  # After the fix trailing ** is stripped; the hook must treat this as well-formed.
  local output
  output="$(python3 -c "
lines = ['All changes look correct.'] * 5
lines.append('')
lines.append('Status: DONE**')
lines.append('Summary: review passed')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "code-reviewer" "$output")"
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  local count
  count="$(find "$HOME/.claude/cast/truncated-agents" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}
