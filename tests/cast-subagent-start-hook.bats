#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-start-hook.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_valid_payload() {
  local agent_name="${1:-test-agent}"
  local session_id="${2:-sess-abc123}"
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type': sys.argv[1],
    'session_id': sys.argv[2],
    'agent_id': 'agent-' + sys.argv[2][:8],
}))
" "$agent_name" "$session_id"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/logs"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  unset CLAUDE_SUBPROCESS
  # Initialize an empty database
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY,
  agent TEXT,
  session_id TEXT,
  status TEXT,
  started_at TEXT,
  agent_id TEXT
);
SQL
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1: Happy path — valid JSON produces event file and DB row
# ---------------------------------------------------------------------------

@test "valid subagent-start JSON → creates event file in cast/events/" {
  run bash "$HOOK_SH" <<< "$(make_valid_payload)"
  assert_success
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" | wc -l)
  [[ "$count" -ge 1 ]]
}

@test "valid subagent-start JSON → creates event file with correct type" {
  bash "$HOOK_SH" <<< "$(make_valid_payload)"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" | head -1)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('event_type') == 'task_claimed', f'event_type={d.get(\"event_type\")}'
assert d.get('agent'), f'missing agent field'
assert d.get('session_id'), f'missing session_id field'
print('ok')
" "$event_file"
}

@test "valid subagent-start JSON → inserts row into agent_runs table" {
  bash "$HOOK_SH" <<< "$(make_valid_payload "my-agent" "sess-xyz789")"
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE agent='my-agent' AND session_id='sess-xyz789';" | tr -d ' ')
  [[ "$count" -eq 1 ]]
}

@test "valid subagent-start JSON → agent_runs row has status=running" {
  bash "$HOOK_SH" <<< "$(make_valid_payload)"
  local status
  status=$(sqlite3 "$CAST_DB_PATH" "SELECT status FROM agent_runs LIMIT 1;" | tr -d ' ')
  [[ "$status" == "running" ]]
}

# ---------------------------------------------------------------------------
# Test 2: Empty stdin — graceful exit
# ---------------------------------------------------------------------------

@test "empty stdin → exits 0 (no-op)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

@test "empty stdin → creates no event files" {
  bash "$HOOK_SH" <<< ""
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" 2>/dev/null | wc -l)
  [[ "$count" -eq 0 ]]
}

@test "empty stdin → creates no DB rows" {
  bash "$HOOK_SH" <<< ""
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs;" | tr -d ' ')
  [[ "$count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Test 3: Error handling — malformed JSON handled gracefully
# ---------------------------------------------------------------------------

@test "malformed JSON → exits 0 (no crash)" {
  run bash "$HOOK_SH" <<< '{"incomplete": json'
  assert_success
}

# ---------------------------------------------------------------------------
# Test 5: JSON missing fields — still creates event/row with defaults
# ---------------------------------------------------------------------------

@test "JSON missing agent_name → uses 'unknown' fallback" {
  run bash "$HOOK_SH" <<< '{"session_id": "sess-123"}'
  assert_success
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*unknown*subagent-start.json" 2>/dev/null | head -1)
  [[ -n "$event_file" ]]
}

@test "JSON missing session_id → still creates event" {
  run bash "$HOOK_SH" <<< '{"agent_type": "test-agent"}'
  assert_success
}

# ---------------------------------------------------------------------------
# Test 6: Multiple consecutive calls — each creates independent event/row
# ---------------------------------------------------------------------------

@test "two consecutive calls → creates two event files" {
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent1" "sess1")"
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent2" "sess2")"
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*subagent-start.json" | wc -l)
  [[ "$count" -ge 2 ]]
}

@test "two consecutive calls → creates two DB rows" {
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent1" "sess1")"
  bash "$HOOK_SH" <<< "$(make_valid_payload "agent2" "sess2")"
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs;" | tr -d ' ')
  [[ "$count" -eq 2 ]]
}

# ---------------------------------------------------------------------------
# J-12 regression: event filenames were built from a second-resolution UTC
# stamp only, so two events landing in the SAME second silently overwrote
# each other on disk (only ONE file survived). A `date` stub freezes both
# invocations onto the identical %Y%m%dT%H%M%SZ second so the collision is
# reproduced deterministically instead of relying on wall-clock luck.
#
# What a PASSING run looks like WHILE THE BUG IS PRESENT: exactly 1 file
# (the second write clobbers the first) — this test requires 2, so it fails
# loudly against the pre-fix filename builder.
# ---------------------------------------------------------------------------

@test "two calls frozen to the SAME second → creates two distinct event files (J-12)" {
  local date_stub_dir="$HOME/.date-stub"
  mkdir -p "$date_stub_dir"
  cat > "$date_stub_dir/date" <<'STUBEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *%Y%m%dT%H%M%SZ*) echo "20260824T120000Z"; exit 0 ;;
    *%Y-%m-%dT%H:%M:%SZ*) echo "2026-08-24T12:00:00Z"; exit 0 ;;
  esac
done
exec /bin/date "$@"
STUBEOF
  chmod +x "$date_stub_dir/date"

  PATH="$date_stub_dir:$PATH" bash "$HOOK_SH" <<< "$(make_valid_payload "burst-agent" "sess-burst-1")"
  PATH="$date_stub_dir:$PATH" bash "$HOOK_SH" <<< "$(make_valid_payload "burst-agent" "sess-burst-2")"

  local count
  count=$(find "$HOME/.claude/cast/events" -name "20260824T120000Z-*burst-agent-subagent-start.json" | wc -l)
  [[ "$count" -eq 2 ]]
}

# ---------------------------------------------------------------------------
# Test 7: Unset session_id → DB row gets NULL not empty-string (FK-orphan fix)
# Phase 5 Wave 2: writers must emit NULL when CAST_SESSION_ID is unresolved.
# ---------------------------------------------------------------------------

@test "JSON missing session_id → agent_runs.session_id is NULL not empty-string" {
  bash "$HOOK_SH" <<< '{"agent_type": "no-sess-agent"}'
  local val
  val=$(sqlite3 "$CAST_DB_PATH" "SELECT COALESCE(session_id, 'IS_NULL') FROM agent_runs WHERE agent='no-sess-agent' LIMIT 1;")
  [[ "$val" == "IS_NULL" ]]
}

# ---------------------------------------------------------------------------
# Test 8: #372-twin guard — no real name AND no agent_id → skip the row,
# keep the event file (unclosable row per reference_subagent_excerpts...).
# ---------------------------------------------------------------------------

@test "no agent name and no agent_id → event file still created" {
  run bash "$HOOK_SH" <<< '{}'
  assert_success
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*unknown*subagent-start.json" 2>/dev/null | wc -l)
  [[ "$count" -ge 1 ]]
}

@test "no agent name and no agent_id → zero agent_runs rows inserted" {
  run bash "$HOOK_SH" <<< '{"session_id": ""}'
  assert_success
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs;" | tr -d ' ')
  [[ "$count" -eq 0 ]]
}

@test "agent_type present but no agent_id/session_id → row IS inserted (lower edge: real name)" {
  run bash "$HOOK_SH" <<< '{"agent_type": "named-no-id"}'
  assert_success
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE agent='named-no-id';" | tr -d ' ')
  [[ "$count" -eq 1 ]]
}

@test "agent_id present, no agent_type, no session_id → row inserted with fields in the right columns" {
  # Real production shape (no workaround): this is the field-placement
  # regression guard for the 0x1f delimiter fix — with the old tab delimiter,
  # the empty middle (session_id) field collapsed and agent_id landed in
  # session_id instead, while AGENT_ID itself came out empty.
  run bash "$HOOK_SH" <<< '{"agent_id": "aid-only-123"}'
  assert_success
  local row
  row=$(sqlite3 "$CAST_DB_PATH" "SELECT agent, COALESCE(session_id, 'IS_NULL'), agent_id FROM agent_runs WHERE agent_id='aid-only-123';")
  [[ "$row" == "unknown|IS_NULL|aid-only-123" ]]
}

@test "named agent + agent_id, no session_id → session_id NULL, agent_id in agent_id column" {
  run bash "$HOOK_SH" <<< '{"agent_type": "named-with-id", "agent_id": "id-1"}'
  assert_success
  local row
  row=$(sqlite3 "$CAST_DB_PATH" "SELECT agent, COALESCE(session_id, 'IS_NULL'), agent_id FROM agent_runs WHERE agent='named-with-id';")
  [[ "$row" == "named-with-id|IS_NULL|id-1" ]]
}

@test "embedded CR in agent_type → sanitised in stored column, fields in correct columns" {
  # Built via python3 json.dumps so the CR is a properly JSON-escaped '\r'
  # (2 chars: backslash, r) in the on-disk payload — the ONLY form json.loads
  # decodes back to a real 0x0d byte. A bash $'...' ANSI-C-quoted heredoc
  # would embed a RAW unescaped CR byte instead, which is invalid JSON under
  # strict json.loads and would fall to the "unknown" parse-error fallback —
  # never reaching clean() at all, making the test pass vacuously either way.
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({'agent_type': 'cr-agent\rX', 'agent_id': 'id-cr-1'}))
")
  # Fixture self-check: confirm the decoded value really contains a literal
  # CR (0x0d), not the two characters '\' and 'r'.
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert chr(13) in d['agent_type'], 'fixture does not contain a real CR byte'
" "$payload"

  run bash "$HOOK_SH" <<< "$payload"
  assert_success
  local row
  row=$(sqlite3 "$CAST_DB_PATH" "SELECT agent, COALESCE(session_id, 'IS_NULL'), agent_id FROM agent_runs WHERE agent_id='id-cr-1';")
  [[ "$row" == "cr-agent X|IS_NULL|id-cr-1" ]]
  # Defensive: the stored agent value must not contain a raw CR byte.
  local raw_agent
  raw_agent=$(sqlite3 "$CAST_DB_PATH" "SELECT agent FROM agent_runs WHERE agent_id='id-cr-1';")
  [[ "$raw_agent" != *$'\r'* ]]
}

@test "malformed JSON → creates no DB rows (preserved behaviour)" {
  bash "$HOOK_SH" <<< '{"incomplete": json'
  local count
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs;" | tr -d ' ')
  [[ "$count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Duplicate SubagentStart for an agent that is still running
#
# Claude Code fires SubagentStart again when the coordinator messages an agent
# that is MID-RUN ("The coordinator sent a message while you were working"),
# but fires only ONE SubagentStop when the run ends. Inserting a second
# 'running' row for the same agent_id left it unclosable (the stop closes
# MIN(id) only) until cast-abandon-stale-runs flipped it to 'abandoned',
# making `cast doctor` report a false "stopped without Status".
# ---------------------------------------------------------------------------

start_payload_for_id() {
  python3 -c "
import json, sys
print(json.dumps({'agent_type': sys.argv[1], 'session_id': 'sess-dup', 'agent_id': sys.argv[2]}))
" "$1" "$2"
}

@test "second SubagentStart for an agent_id that is still running → no second row" {
  bash "$HOOK_SH" <<< "$(start_payload_for_id security aid-dup-1)"
  bash "$HOOK_SH" <<< "$(start_payload_for_id security aid-dup-1)"
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE agent_id='aid-dup-1';"
  assert_success
  assert_output "1"
}

@test "SubagentStart after the previous run for that agent_id finished (resume) → new row" {
  bash "$HOOK_SH" <<< "$(start_payload_for_id security aid-resume-1)"
  sqlite3 "$CAST_DB_PATH" "UPDATE agent_runs SET status='DONE' WHERE agent_id='aid-resume-1';"
  bash "$HOOK_SH" <<< "$(start_payload_for_id security aid-resume-1)"
  run sqlite3 "$CAST_DB_PATH" "SELECT status FROM agent_runs WHERE agent_id='aid-resume-1' ORDER BY id;"
  assert_success
  assert_output "$(printf 'DONE\nrunning')"
}

@test "duplicate-start guard is per agent_id → a different running agent_id still gets its own row" {
  bash "$HOOK_SH" <<< "$(start_payload_for_id security aid-a)"
  bash "$HOOK_SH" <<< "$(start_payload_for_id security aid-b)"
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE status='running';"
  assert_success
  assert_output "2"
}

@test "two SubagentStarts with NO agent_id → two rows (no dedupe without an id)" {
  local p
  p="$(python3 -c "
import json
print(json.dumps({'agent_type': 'security', 'session_id': 'sess-noid'}))
")"
  bash "$HOOK_SH" <<< "$p"
  bash "$HOOK_SH" <<< "$p"
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs WHERE agent='security';"
  assert_success
  assert_output "2"
}

# ---------------------------------------------------------------------------
# Review snapshot (content-bound review gate): reviewers only
# ---------------------------------------------------------------------------

make_dirty_repo() {
  REVIEW_REPO="$BATS_TEST_TMPDIR/rev-repo"
  mkdir -p "$REVIEW_REPO"
  git -C "$REVIEW_REPO" init -q
  echo dirty > "$REVIEW_REPO/f.txt"
}

make_reviewer_payload() {
  python3 -c "
import json, sys
print(json.dumps({'agent_type': sys.argv[1], 'session_id': 's-rev', 'agent_id': 'agent-rev1', 'cwd': sys.argv[2]}))
" "$1" "$REVIEW_REPO"
}

@test "code-reviewer SubagentStart writes a start snapshot state file" {
  make_dirty_repo
  run bash "$HOOK_SH" <<< "$(make_reviewer_payload code-reviewer)"
  assert_success
  [ -f "$HOME/.claude/cast-state/review-snapshots/agent-rev1.json" ]
  grep -q '"f.txt"' "$HOME/.claude/cast-state/review-snapshots/agent-rev1.json"
}

@test "non-reviewer SubagentStart writes no start snapshot" {
  make_dirty_repo
  run bash "$HOOK_SH" <<< "$(make_reviewer_payload backend-writer)"
  assert_success
  [ ! -e "$HOME/.claude/cast-state/review-snapshots/agent-rev1.json" ]
}

@test "empty session_id and no cwd in a reviewer payload: fields stay in their columns, snapshot from PWD" {
  make_dirty_repo
  local p
  p="$(python3 -c "
import json
print(json.dumps({'agent_type': 'code-reviewer', 'agent_id': 'agent-rev2'}))
")"
  run bash -c 'cd "$1" && bash "$2" <<< "$3"' _ "$REVIEW_REPO" "$HOOK_SH" "$p"
  assert_success
  run sqlite3 "$CAST_DB_PATH" "SELECT agent || '|' || IFNULL(session_id,'') || '|' || agent_id FROM agent_runs WHERE agent='code-reviewer';"
  assert_output "code-reviewer||agent-rev2"
  [ -f "$HOME/.claude/cast-state/review-snapshots/agent-rev2.json" ]
}

@test "CAST_HOOK_DIR from the environment is ignored for the snapshot helper" {
  make_dirty_repo
  local evil="$BATS_TEST_TMPDIR/evil"
  mkdir -p "$evil"
  printf 'import sys\nopen(%s, "w").write("pwned")\n' "'$evil/pwned'" > "$evil/cast_review_snapshot.py"
  CAST_HOOK_DIR="$evil" run bash "$HOOK_SH" <<< "$(make_reviewer_payload code-reviewer)"
  assert_success
  [ ! -e "$evil/pwned" ]
  [ -f "$HOME/.claude/cast-state/review-snapshots/agent-rev1.json" ]
}
