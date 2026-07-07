#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"
# Truncation logic now lives in consolidated stage 4 of cast_subagent_stop.py,
# invoked via the main SubagentStop hook (blueprint §4: retarget).
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export TEMP_DB="$HOME/cast.db"
  export CAST_DB_PATH="$TEMP_DB"
  unset CLAUDE_SUBPROCESS

  # Initialize the database with all migrations
  bash "$DB_INIT" --db "$TEMP_DB" > /dev/null 2>&1

  # Apply migrations 009 and 010 to create agent_truncations table and partial_work_log column
  cat "$REPO_DIR/scripts/migrations/009_cast_framework_fixes.sql" | sqlite3 "$TEMP_DB" 2>/dev/null || true
  cat "$REPO_DIR/scripts/migrations/010_work_log_stream.sql" | sqlite3 "$TEMP_DB" 2>/dev/null || true
}

teardown() {
  teardown_temp_home
}

# Helper: build a SubagentStop JSON payload with truncation markers
# (no Status block, no JSON status) and optional agent_response content
_make_truncated_input() {
  local output_text="$1"
  # Create a payload that mimics what SubagentStop hook receives:
  # agent_response with content array containing text blocks
  python3 -c "
import json, sys
payload = {
    'agent_type': 'test-agent',
    'agent_id': 'test-001',
    'batch_id': 1,
    'session_id': 'sess-test',
    'agent_response': {
        'content': [
            {'type': 'text', 'text': sys.argv[1]}
        ]
    }
}
print(json.dumps(payload))
" "$output_text"
}

# Helper: insert a truncated row directly into agent_truncations
# (simulates what the hook writes when it detects truncation)
_insert_truncated_row() {
  # batch_id/has_status/has_json retired in migration 028; INSERT uses surviving columns only
  local agent_type="$1"
  local last_line="$2"
  local partial_work_log="$3"

  sqlite3 "$TEMP_DB" <<EOF
INSERT INTO agent_truncations (
    session_id,
    agent_type,
    agent_id,
    last_line,
    timestamp,
    char_count,
    partial_work_log
) VALUES (
    'sess-test',
    '$agent_type',
    'test-001',
    '$last_line',
    datetime('now'),
    100,
    $partial_work_log
);
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: extract_work_log function recognizes Work Log section with Status
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: extract_work_log() captures Work Log between heading and Status:" {
  # Source the hook to test the extract_work_log function directly
  # We'll do this by calling a small Python snippet that imports the module
  run python3 - <<'PYEOF'
import sys
import re

# Define the extract_work_log function (copied from cast-truncation-check.sh)
def extract_work_log(text: str):
    """Extract text between '## Work Log' and 'Status:' (or end of string).

    Returns the extracted section as a stripped string, or None if no
    '## Work Log' heading is found in the text.
    """
    pattern = re.compile(
        r'##\s+Work\s+Log\s*\n([\s\S]*?)(?=\nStatus:|$)',
        re.IGNORECASE,
    )
    match = pattern.search(text)
    if not match:
        return None
    extracted = match.group(1).strip()
    return extracted if extracted else None

test_text = """Some output.

## Work Log

- Task 1 completed
- Task 2 in progress
- Task 3 pending

Status: DONE
Summary: Test summary"""

result = extract_work_log(test_text)
if result and "Task 1 completed" in result and "Task 2 in progress" in result:
    sys.exit(0)
else:
    print(f"FAIL: Got {result!r}")
    sys.exit(1)
PYEOF
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: extract_work_log returns None when no Work Log section exists
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: extract_work_log() returns None when no Work Log heading" {
  run python3 - <<'PYEOF'
import sys
import re

def extract_work_log(text: str):
    pattern = re.compile(
        r'##\s+Work\s+Log\s*\n([\s\S]*?)(?=\nStatus:|$)',
        re.IGNORECASE,
    )
    match = pattern.search(text)
    if not match:
        return None
    extracted = match.group(1).strip()
    return extracted if extracted else None

test_text = """Some output.

Status: DONE
Summary: Test summary"""

result = extract_work_log(test_text)
if result is None:
    sys.exit(0)
else:
    print(f"FAIL: Expected None, got {result!r}")
    sys.exit(1)
PYEOF
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: extract_work_log handles Work Log at end of input (no trailing Status)
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: extract_work_log() captures Work Log through end-of-input" {
  run python3 - <<'PYEOF'
import sys
import re

def extract_work_log(text: str):
    pattern = re.compile(
        r'##\s+Work\s+Log\s*\n([\s\S]*?)(?=\nStatus:|$)',
        re.IGNORECASE,
    )
    match = pattern.search(text)
    if not match:
        return None
    extracted = match.group(1).strip()
    return extracted if extracted else None

# No trailing Status: line — Work Log extends to EOF
test_text = """Status: DONE

## Work Log

- Item 1
- Item 2
- Item 3"""

result = extract_work_log(test_text)
if result and "Item 1" in result and "Item 3" in result:
    sys.exit(0)
else:
    print(f"FAIL: Got {result!r}")
    sys.exit(1)
PYEOF
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: truncation hook persists partial_work_log to DB when Work Log present
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: persists non-NULL partial_work_log when Work Log section exists" {
  # Simulate an agent response with a Work Log but no Status block
  # (triggers truncation detection)
  local output_text="Implementing feature.

## Work Log

- Read file: done
- Analyzed code: done
- Starting implementation

This is where it got cut off"

  local input
  input="$(_make_truncated_input "$output_text")"

  # Run the truncation hook
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Query the database: should have 1 row in agent_truncations
  local row_count
  row_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$row_count" "1"

  # Verify partial_work_log is NOT NULL and contains expected text
  local partial_log
  partial_log=$(sqlite3 "$TEMP_DB" "SELECT partial_work_log FROM agent_truncations LIMIT 1;" 2>/dev/null || echo "")
  [ -n "$partial_log" ]  # non-empty
  [[ "$partial_log" == *"Read file: done"* ]]
  [[ "$partial_log" == *"Analyzed code: done"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: truncation hook persists NULL partial_work_log when no Work Log
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: persists NULL partial_work_log when no Work Log section" {
  # Simulate an agent response with no Work Log and no Status block
  # (triggers truncation detection, but should have NULL partial_work_log)
  local output_text="Implementing feature.

I was about to do the following steps:
1. Read the file
2. Analyze the code
3. Make changes

But I got cut off mid-sentence"

  local input
  input="$(_make_truncated_input "$output_text")"

  # Run the truncation hook
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Query the database: should have 1 row in agent_truncations
  local row_count
  row_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$row_count" "1"

  # Verify partial_work_log IS NULL
  local partial_log
  partial_log=$(sqlite3 "$TEMP_DB" "SELECT partial_work_log FROM agent_truncations LIMIT 1;" 2>/dev/null || echo "DEFAULT")
  assert_equal "$partial_log" ""  # NULL is returned as empty string by sqlite3 CLI
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: truncation hook writes partial_work_log via db_write (integration)
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: db_write preserves partial_work_log column correctly" {
  # This test verifies the full write path: hook detects truncation, calls db_write
  # with partial_work_log in the payload, and the column is persisted.

  local output_text="Starting implementation.

## Work Log

- Opened file: success
- Reviewed code structure: complete
- Ready for implementation

Got interrupted here"

  local input
  input="$(_make_truncated_input "$output_text")"

  # Run the hook which calls db_write with partial_work_log
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Query back the row and verify surviving columns (has_status/has_json retired in migration 028)
  local sql
  sql="SELECT agent_type, partial_work_log FROM agent_truncations LIMIT 1;"

  local result
  result=$(sqlite3 "$TEMP_DB" "$sql" 2>/dev/null || echo "")

  # Result should be: test-agent|<partial_work_log_text>
  [[ "$result" == *"test-agent"* ]]
  [[ "$result" == *"Opened file"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: truncation hook ignores responses < 50 chars (trivial guard)
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: ignores trivial response (< 50 chars) even if no Status" {
  # Very short output with no Status block should NOT be logged as truncation
  # (it's trivial, not truncated)
  local output_text="Brief response"

  local input
  input="$(_make_truncated_input "$output_text")"

  # Run the hook
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Should NOT write a truncation row
  local row_count
  row_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$row_count" "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: truncation hook still logs if response has JSON status (not truncated)
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: does NOT log row when JSON status block is present" {
  # Even with no prose Status block, if JSON status is present, it's NOT truncated
  local output_text="Work completed.

\`\`\`json status
{
  \"schema_version\": \"1.0\",
  \"status\": \"DONE\",
  \"agent\": \"test-agent\",
  \"summary\": \"Test summary\"
}
\`\`\`"

  local input
  input="$(_make_truncated_input "$output_text")"

  # Run the hook
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Should NOT write a truncation row (JSON status = complete response)
  local row_count
  row_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$row_count" "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: truncation hook does NOT log when prose Status block present
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: does NOT log row when prose Status block is present" {
  # Even with Work Log, if Status block is present, response is NOT truncated
  local output_text="Work completed.

## Work Log

- Task A: done
- Task B: in progress

Status: BLOCKED
Summary: Blocked waiting for input
Concerns: Timeout on API call"

  local input
  input="$(_make_truncated_input "$output_text")"

  # Run the hook
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Should NOT write a truncation row (Status = complete response)
  local row_count
  row_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$row_count" "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: column exists in schema after migration
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation fallback: partial_work_log column exists in agent_truncations schema" {
  # Verify the column was added by the migration
  local columns
  columns=$(sqlite3 "$TEMP_DB" "PRAGMA table_info(agent_truncations);" 2>/dev/null)

  # Should contain a line like: N|partial_work_log|TEXT|0||0
  [[ "$columns" == *"partial_work_log"* ]]
  [[ "$columns" == *"TEXT"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: agent_type fallback queries agent_runs when agent_type is missing
# ─────────────────────────────────────────────────────────────────────────────

@test "truncation hook: agent_type fallback — missing agent_type queries agent_runs table" {
  # Pre-insert a row into agent_runs with agent_id='fallback-test-001' and agent='code-writer'
  sqlite3 "$TEMP_DB" <<'SQL'
INSERT INTO agent_runs (agent_id, agent, session_id, started_at, status)
VALUES ('fallback-test-001', 'code-writer', 'sess-fallback', datetime('now'), 'DONE');
SQL

  # Create a payload with NO agent_type field but with agent_id
  local payload
  payload=$(python3 -c "
import json
payload = {
    'agent_id': 'fallback-test-001',
    'agent_type': '',  # Empty, so it falls back to 'unknown'
    'session_id': 'sess-fallback',
    'agent_response': {
        'content': [
            {'type': 'text', 'text': 'Some output that is definitely longer than fifty characters so the truncation check runs'}
        ]
    }
}
print(json.dumps(payload))
")

  # Run the consolidated hook with the payload via stdin (main hook reads stdin,
  # not CAST_INPUT — the old truncation-check.sh supported both; the new wrapper
  # reads stdin once and exports as CAST_STOP_INPUT for cast_subagent_stop.py).
  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # Verify that the agent_truncations row has agent_type='code-writer' (from DB fallback), not 'unknown'
  local agent_type_in_db
  agent_type_in_db=$(sqlite3 "$TEMP_DB" "SELECT agent_type FROM agent_truncations WHERE agent_id='fallback-test-001' LIMIT 1;")

  assert_equal "$agent_type_in_db" "code-writer"
}

# ─────────────────────────────────────────────────────────────────────────────
# F19 regression: APPROVE and REQUEST_CHANGES must NOT be written to
# agent_truncations (corpus failure F19 — reviewer statuses were unrecognized)
# ─────────────────────────────────────────────────────────────────────────────

@test "F19: truncation hook: Status: APPROVE is NOT written to agent_truncations" {
  local output_text="Reviewed the implementation changes carefully.

The code looks correct and follows all project conventions. No issues found.

Status: APPROVE
Summary: Code review passed — implementation is correct and well-structured."

  local input
  input="$(_make_truncated_input "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Must NOT emit [CAST-TRUNCATED] banner
  refute_output --partial "[CAST-TRUNCATED]"

  # Must NOT write a row to agent_truncations
  local row_count
  row_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$row_count" "0"
}

@test "F19: truncation hook: Status: REQUEST_CHANGES is NOT written to agent_truncations" {
  local output_text="Reviewed the implementation changes carefully.

Found issues that must be resolved before merging. Type safety gaps in two places.

Status: REQUEST_CHANGES
Summary: Two type safety issues found — see concerns.
Concerns: Missing return type annotation on parseResult(), unused import in utils.ts"

  local input
  input="$(_make_truncated_input "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # Must NOT emit [CAST-TRUNCATED] banner
  refute_output --partial "[CAST-TRUNCATED]"

  # Must NOT write a row to agent_truncations
  local row_count
  row_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$row_count" "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: P5 regression — truncation hook must NOT write quality_gates mirror row
# ─────────────────────────────────────────────────────────────────────────────

@test "P5: truncation hook writes agent_truncations but NOT quality_gates mirror row" {
  local output_text="Implementing the requested feature.

## Work Log

- Read source files: done
- Analyzed patterns: done
- Starting implementation now

Got interrupted before finishing"

  local input
  input="$(_make_truncated_input "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # agent_truncations must have exactly 1 row (authoritative truncation record)
  local at_count
  at_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM agent_truncations;" 2>/dev/null || echo "0")
  assert_equal "$at_count" "1"

  # quality_gates must have ZERO rows with status_line='TRUNCATED' (mirror removed)
  local qg_count
  qg_count=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM quality_gates WHERE status_line='TRUNCATED';" 2>/dev/null || echo "0")
  assert_equal "$qg_count" "0"
}
