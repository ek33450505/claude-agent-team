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
