#!/usr/bin/env bats
# tests/cast-subagent-stop-consolidated.bats
#
# Six new tests for the cast_subagent_stop.py consolidated processor.
# Blueprint: plans/w2-1-subagentstop-consolidation-blueprint.md §4.
#
# Each test invokes cast_subagent_stop.py (or the full bash wrapper for test 6)
# against an isolated temp HOME — never the real ~/.claude — and validates the
# six new correctness properties introduced by the consolidation:
#
#   1. Partial-failure isolation: a poisoned stage does not kill later stages.
#   2. Single truncation write: exactly ONE agent_truncations row per event.
#   3. Budget ordering: alert fires in the SAME event that crosses the threshold.
#   4. Duration p95 in-process: slow_agent row without a separate hook invocation.
#   5. Multi-banner stdout: each hookSpecificOutput line is valid standalone JSON.
#   6. Real-default-path probe: no env overrides → completeness + truncation rows.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"
PY_MOD="$REPO_DIR/scripts/cast_subagent_stop.py"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Initialise a full cast.db at $1 (all tables the consolidation stages need).
_init_db() {
  local db="$1"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$db" 2>/dev/null || true
}

# Build a SubagentStop JSON payload using last_assistant_message.
# $1 = agent_type   $2 = output text
_make_payload() {
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type':             sys.argv[1],
    'session_id':             'sess-cons-test',
    'stop_reason':            'end_turn',
    'last_assistant_message': sys.argv[2],
}))
" "$1" "$2"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/cast/truncated-agents"
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/.claude/cast.db"
  _init_db "$TEST_DB"
  unset CLAUDE_SUBPROCESS
  unset CAST_DB_PATH
  unset CAST_HOOK_DIR
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1: Partial-failure isolation
#
# Drop the incidents table → stage 15 INSERT fails → stage 16 (hookSpecificOutput)
# still fires AND a hook_failures row is recorded for the failed insert.
# This replaces the per-heredoc `|| true` isolation the old monolithic hook gave.
# ---------------------------------------------------------------------------

@test "consolidated: partial-failure isolation — poisoned incidents table does not kill stage 16" {
  # Seed a running row so stage 0 has something to close (not required for isolation
  # correctness but keeps stage 0 noise-free in the hook_failures table).
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, session_id, status, started_at)
     VALUES ('debugger','sess-cons-test','running','2026-01-01T00:00:00Z');"

  # Poison stage 15: drop incidents so its INSERT raises OperationalError.
  sqlite3 "$TEST_DB" "DROP TABLE IF EXISTS incidents;"

  # debugger + Status: DONE → stage 15 tries (and fails) to record an incident.
  local out_text
  out_text="Investigated the issue and found the root cause in the parser module.

Summary: fixed the null pointer dereference in core/parser.c
Files changed: core/parser.c

Status: DONE"

  local payload
  payload="$(_make_payload "debugger" "$out_text")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  # Stage 16 must still emit a compressed hookSpecificOutput (stage crash was isolated).
  assert_output --partial "hookSpecificOutput"

  # hook_failures must record the stage-15 incident_insert failure.
  local fail_count
  fail_count="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM hook_failures WHERE hook_name LIKE '%incident%';")"
  [[ "$fail_count" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# Test 2: Single truncation write
#
# One SubagentStop event for a non-exempt agent with structured content and no
# Status block → exactly ONE agent_truncations row. Locks the double-write fix
# (blueprint §6.5): the deleted cast-truncation-check.sh was writing a second row.
# ---------------------------------------------------------------------------

@test "consolidated: single truncation write — exactly one agent_truncations row per event" {
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, session_id, status, started_at)
     VALUES ('code-writer','sess-cons-test','running','2026-01-01T00:00:00Z');"

  # < 200 chars + no Status + ends with colon → compute_trunc_class returns 2.
  local out_text
  out_text="I have started implementing the requested changes to the configuration file:"

  local payload
  payload="$(_make_payload "code-writer" "$out_text")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  # Exactly ONE row — not zero (stage 4 must have fired), not two (double-write fixed).
  local row_count
  row_count="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM agent_truncations WHERE session_id='sess-cons-test';")"
  [[ "$row_count" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Test 3: Budget ordering — alert fires on the same event that crosses the threshold
#
# Pre-seed today's agent_runs with spend already above the warning threshold.
# Stage 14 (budget) runs AFTER stage 2 (cost commit), so it reads the up-to-date
# SUM in this same invocation — the old separate-hook approach could read stale data
# and miss the alert on the first crossing event.
# ---------------------------------------------------------------------------

@test "consolidated: budget ordering — alert fires on the same event that crosses the threshold" {
  # Budget: $10.00 daily limit, alert at 80%.
  sqlite3 "$TEST_DB" \
    "INSERT INTO budgets (scope, scope_key, period, limit_usd, alert_at_pct, created_at)
     VALUES ('global','*','daily',10.0,0.80,datetime('now'));"

  # Pre-seed $8.50 of today's spend (85% of limit → already over threshold).
  local today
  today="$(date -u +%Y-%m-%d)"
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, session_id, status, started_at, cost_usd)
     VALUES ('x','s-budget-prior','DONE','${today}T08:00:00Z',8.50);"

  local payload
  payload="$(_make_payload "test-agent" "Status: DONE
Summary: completed the assigned task successfully.")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  # Banner must appear in THIS invocation (not a later one).
  assert_output --partial "[CAST-BUDGET-WARN]"

  # O_EXCL marker must have been created (exactly-once dedup guard).
  local day_compact
  day_compact="$(date -u +%Y%m%d)"
  [[ -f "$HOME/.claude/cast/budget-alert-${day_compact}.flag" ]]
}

# ---------------------------------------------------------------------------
# Test 4: Duration p95 in-process
#
# Seed 5+ historical duration_ms rows for 'slow-agent'; present a slow run that
# exceeds p95. Assert routing_events(slow_agent) is written entirely in-process
# (stage 13, no external cast-duration-check.sh required — that script is deleted).
# ---------------------------------------------------------------------------

@test "consolidated: duration p95 in-process — routing_events slow_agent row without separate hook" {
  local today
  today="$(date -u +%Y-%m-%d)"

  # 5 historical rows for 'slow-agent' within the 30-day query window.
  for ms in 1000 2000 3000 4000 5000; do
    sqlite3 "$TEST_DB" \
      "INSERT INTO agent_runs (agent, session_id, status, started_at, ended_at, duration_ms)
       VALUES ('slow-agent','s-hist-${ms}','DONE',
               '${today}T09:00:00Z','${today}T09:00:01Z',${ms});"
  done

  # Running row started 60 seconds ago → stage 2 computes duration ~60000 ms (> p95).
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, session_id, status, started_at)
     VALUES ('slow-agent','sess-cons-test','running',datetime('now','-60 seconds'));"

  local payload
  payload="$(_make_payload "slow-agent" "Status: DONE
Summary: the slow task completed successfully.")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  # routing_events must have a slow_agent row for this agent — written in-process.
  local slow_count
  slow_count="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM routing_events
     WHERE event_type='slow_agent' AND matched_route='slow-agent';")"
  [[ "$slow_count" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# Test 5: Multi-banner stdout
#
# Trigger truncation banner (stage 12, trunc_class==2) AND budget banner (stage 14)
# AND compressed context (stage 16) in a single invocation. Assert every line that
# contains hookSpecificOutput is valid standalone JSON — each line independently
# parseable without the others.
# ---------------------------------------------------------------------------

@test "consolidated: multi-banner stdout — each hookSpecificOutput line is valid standalone JSON" {
  # Budget: $10.00 limit, alert at 80%; pre-seeded over threshold.
  sqlite3 "$TEST_DB" \
    "INSERT INTO budgets (scope, scope_key, period, limit_usd, alert_at_pct, created_at)
     VALUES ('global','*','daily',10.0,0.80,datetime('now'));"

  local today
  today="$(date -u +%Y-%m-%d)"
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, session_id, status, started_at, cost_usd)
     VALUES ('x','s-budget2','DONE','${today}T07:00:00Z',9.50);"

  # code-writer + no Status + ends with colon → trunc_class==2 → stage 12 truncation banner.
  local out_text
  out_text="I have started implementing the changes and will continue by editing the file:"

  local payload
  payload="$(_make_payload "code-writer" "$out_text")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  # Parse every hookSpecificOutput line as standalone JSON; fail on any invalid line.
  local py_result
  py_result="$(python3 -c "
import json, sys
lines = sys.argv[1].splitlines()
errors = []
hso_count = 0
for i, line in enumerate(lines):
    if 'hookSpecificOutput' not in line:
        continue
    hso_count += 1
    try:
        obj = json.loads(line)
        assert 'hookSpecificOutput' in obj, 'missing hookSpecificOutput key'
    except Exception as e:
        errors.append('line ' + str(i) + ': ' + repr(e) + ': ' + line[:80])
if errors:
    print('FAIL:' + '; '.join(errors))
    sys.exit(1)
elif hso_count == 0:
    print('FAIL: no hookSpecificOutput lines found')
    sys.exit(1)
else:
    print('OK:' + str(hso_count))
" "$output")"

  # Every hookSpecificOutput line is valid standalone JSON.
  [[ "$py_result" == OK:* ]]

  # At least 2 banners: truncation (stage 12) + budget (stage 14).
  local banner_count
  banner_count="${py_result#OK:}"
  [[ "$banner_count" -ge 2 ]]
}

# ---------------------------------------------------------------------------
# Test 6: Real-default-path probe
#
# Run the full bash wrapper (cast-subagent-stop-hook.sh) with NO CAST_DB_PATH or
# CAST_HOOK_DIR overrides. The hook resolves the DB from $HOME/.claude/cast.db
# (already initialised by setup) and HOOK_DIR from dirname "$0" (the repo scripts
# dir). Asserts completeness_events + agent_truncations rows appear — the gate rule
# from working-conventions: probe the REAL default path before declaring the feature
# done.
# ---------------------------------------------------------------------------

@test "consolidated: real-default-path probe — no env overrides, completeness and truncation rows appear" {
  # DB at $HOME/.claude/cast.db created by setup(); no CAST_DB_PATH override needed.
  # Hook's HOOK_DIR = dirname of $HOOK_SH = $REPO_DIR/scripts (auto-set by the wrapper).

  local out_text
  out_text="I am making the requested changes to the module by editing several source files"

  local payload
  payload="$(_make_payload "code-writer" "$out_text")"

  # Run the full wrapper — no CAST_DB_PATH, no CAST_HOOK_DIR environment override.
  run bash "$HOOK_SH" <<< "$payload"
  assert_success

  # completeness_events row: stage 5 fires for non-exempt + non-empty + no Status.
  local ce_count
  ce_count="$(sqlite3 "$HOME/.claude/cast.db" \
    "SELECT COUNT(*) FROM completeness_events WHERE agent='code-writer';" 2>/dev/null || echo 0)"
  [[ "$ce_count" -ge 1 ]]

  # agent_truncations row: stage 4 fires for non-exempt + no Status + >= 50 chars.
  local at_count
  at_count="$(sqlite3 "$HOME/.claude/cast.db" \
    "SELECT COUNT(*) FROM agent_truncations WHERE agent_type='code-writer';" 2>/dev/null || echo 0)"
  [[ "$at_count" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# Test 7a: Stage 7 prose-dispatch — violation row written
#
# Port of test_cast_agent_protocol_check.bats test 2 (deleted when the standalone
# script was removed). Prose text starting with "Dispatching …" and no matching
# tool_use block → stage7_protocol_check writes an agent_protocol_violations row
# and emits a [CAST-WARN] line to stderr.
# ---------------------------------------------------------------------------

@test "consolidated: stage7 prose-dispatch — violation row written and stderr warning emitted" {
  local out_text
  out_text="Dispatching code-reviewer per CAST conventions."

  local payload
  payload="$(_make_payload "code-writer" "$out_text")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  # Stage 7 must have written a prose_dispatch violation row.
  local viol_count
  viol_count="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM agent_protocol_violations
     WHERE agent_type='code-writer' AND violation='prose_dispatch';")"
  [[ "$viol_count" -ge 1 ]]

  # Stderr warning must reference the CAST-WARN marker.
  assert_output --partial "[CAST-WARN]"
}

# ---------------------------------------------------------------------------
# Test 7b: Stage 7 prose-dispatch — normal output produces no violation
#
# Port of test_cast_agent_protocol_check.bats test 3 (deleted). An output that
# contains an actual tool_use count suppresses the violation even when prose
# dispatch language is present. Here we use clean output with no dispatch
# language to confirm the negative path: no row is written for ordinary output.
# ---------------------------------------------------------------------------

@test "consolidated: stage7 prose-dispatch — clean output produces no violation row" {
  local out_text
  # No "Dispatching …" at the start of any line — stage 7 must stay silent.
  out_text="Status: DONE
Summary: implemented the requested feature successfully.
Files changed: src/foo.py"

  local payload
  payload="$(_make_payload "code-writer" "$out_text")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  local viol_count
  viol_count="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM agent_protocol_violations
     WHERE agent_type='code-writer' AND violation='prose_dispatch';")"
  [[ "$viol_count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Test 8: transcript tool_use count — stage2_transcript_cost populates tool_uses
#
# Before this fix, tool_uses was a dead producer: only 2 of 6798 rows were non-zero
# because the SubagentStop payload never carries tool_use data. stage2_transcript_cost
# now counts type:"tool_use" content blocks from the transcript JSONL and overrides
# the payload zero, mirroring the existing cache-token override pattern.
# ---------------------------------------------------------------------------

@test "consolidated: transcript tool_use count — tool_uses populated from transcript blocks not payload" {
  local sess_id="sess-transcript-tool-uses"
  local agent_id="aid-transcript-tu-001"

  # Seed a running row with the matching agent_id so stage 0 can close it and
  # stage 2 can update it (the UPDATE targets fast_row_id or agent_id match).
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at)
     VALUES ('test-agent','$sess_id','$agent_id','running','2026-01-01T00:00:00Z');"

  # Create transcript file at the glob path:
  # ~/.claude/projects/*/{session_id}/subagents/**/agent-{agent_id}.jsonl
  local transcript_dir="$HOME/.claude/projects/test-proj/$sess_id/subagents"
  mkdir -p "$transcript_dir"
  local transcript_file="$transcript_dir/agent-$agent_id.jsonl"

  # 3 messages: msg1 has 1 tool_use, msg2 has 2 tool_uses, msg3 has text only.
  # Total = 3. Use printf (not heredoc) to avoid BATS @test line-rewrite gotcha.
  printf '%s\n' \
    '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{}}],"usage":{"input_tokens":100,"output_tokens":20}}}' \
    '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Edit","input":{}},{"type":"tool_use","id":"tu3","name":"Bash","input":{}}],"usage":{"input_tokens":80,"output_tokens":30}}}' \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":60,"output_tokens":10}}}' \
    > "$transcript_file"

  # Payload carries NO tool_use fields — the production SubagentStop never does.
  local payload
  payload="$(python3 -c "
import json, sys
print(json.dumps({
    'agent_type':             'test-agent',
    'session_id':             sys.argv[1],
    'agent_id':               sys.argv[2],
    'stop_reason':            'end_turn',
    'last_assistant_message': 'Status: DONE\nSummary: completed task.',
}))
" "$sess_id" "$agent_id")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  local tool_uses
  tool_uses="$(sqlite3 "$TEST_DB" \
    "SELECT tool_uses FROM agent_runs WHERE agent_id='$agent_id';")"

  # Must be 3 (from transcript), not 0 (payload default before this fix).
  [[ "$tool_uses" -eq 3 ]]
}

# ---------------------------------------------------------------------------
# Test 9: transcript edited files — stage2_transcript_cost populates files + file_class
#
# F2: when the transcript contains Edit/Write tool_use blocks, stage 2 extracts
# the file_path values, stores them as a JSON array in agent_runs.files, and
# derives a severity class in agent_runs.file_class.  A .py + .md → "code" wins.
# ---------------------------------------------------------------------------

@test "consolidated: transcript edited files — files and file_class populated from transcript Edit/Write blocks" {
  local sess_id="sess-transcript-files"
  local agent_id="aid-transcript-files-001"

  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_runs (agent, session_id, agent_id, status, started_at)
     VALUES ('test-agent','$sess_id','$agent_id','running','2026-01-01T00:00:00Z');"

  local transcript_dir="$HOME/.claude/projects/test-proj/$sess_id/subagents"
  mkdir -p "$transcript_dir"
  local transcript_file="$transcript_dir/agent-$agent_id.jsonl"

  # Two Edit blocks (distinct file_paths), one Write block (same .py file), one Bash (no file).
  # Use printf to avoid BATS @test heredoc line-rewrite gotcha.
  printf '%s\n' \
    '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"e1","name":"Edit","input":{"file_path":"/repo/src/foo.py","old_string":"a","new_string":"b"}}],"usage":{"input_tokens":100,"output_tokens":20}}}' \
    '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"e2","name":"Write","input":{"file_path":"/repo/docs/README.md","content":"x"}}],"usage":{"input_tokens":50,"output_tokens":10}}}' \
    '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"e3","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":30,"output_tokens":5}}}' \
    > "$transcript_file"

  local payload
  payload="$(python3 -c "
import json, sys
print(json.dumps({
    'agent_type':             'test-agent',
    'session_id':             sys.argv[1],
    'agent_id':               sys.argv[2],
    'stop_reason':            'end_turn',
    'last_assistant_message': 'Status: DONE\nSummary: task done.',
}))
" "$sess_id" "$agent_id")"

  run env CAST_DB_PATH="$TEST_DB" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    CAST_STOP_INPUT="$payload" \
    python3 "$PY_MOD"

  assert_success

  local files_json file_class
  files_json="$(sqlite3 "$TEST_DB" \
    "SELECT files FROM agent_runs WHERE agent_id='$agent_id';")"
  file_class="$(sqlite3 "$TEST_DB" \
    "SELECT file_class FROM agent_runs WHERE agent_id='$agent_id';")"

  # Both edited paths must appear in the JSON array.
  [[ "$files_json" == *"foo.py"* ]]
  [[ "$files_json" == *"README.md"* ]]
  # .py is "code" (rank 3), .md is "docs" (rank 1) → highest = "code".
  [[ "$file_class" == "code" ]]
}

# ---------------------------------------------------------------------------
# Test 10: classify_files unit assertions (pure-function, no DB required)
# ---------------------------------------------------------------------------

@test "consolidated: classify_files — enforcement wins over test and code" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/scripts')
from cast_subagent_stop import classify_files
# scripts/ path → enforcement
r = classify_files(['/repo/x/scripts/h.py'])
assert r == 'enforcement', f'expected enforcement, got {r!r}'
# .bats → test
r2 = classify_files(['/repo/tests/a.bats'])
assert r2 == 'test', f'expected test, got {r2!r}'
# .md → docs
r3 = classify_files(['a.md'])
assert r3 == 'docs', f'expected docs, got {r3!r}'
print('ok')
"
  assert_success
  assert_output 'ok'
}

@test "consolidated: classify_files — mixed paths yield highest-rank class" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/scripts')
from cast_subagent_stop import classify_files
# mix: docs + enforcement → enforcement
r = classify_files(['a.md', '/repo/x/scripts/h.py'])
assert r == 'enforcement', f'expected enforcement, got {r!r}'
# mix: docs + test → test
r2 = classify_files(['README.md', '/proj/tests/foo.test.ts'])
assert r2 == 'test', f'expected test, got {r2!r}'
print('ok')
"
  assert_success
  assert_output 'ok'
}

@test "consolidated: classify_files — empty list returns empty string" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/scripts')
from cast_subagent_stop import classify_files
r = classify_files([])
assert r == '', f'expected empty string, got {r!r}'
# Non-str entries skipped defensively
r2 = classify_files([None, 42, 'a.json'])
assert r2 == 'config', f'expected config, got {r2!r}'
print('ok')
"
  assert_success
  assert_output 'ok'
}
