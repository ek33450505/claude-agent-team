#!/usr/bin/env bats
# Tests for cast-abandon-stale-runs.py
# Covers: agent_runs abandoned step + new sessions crash-marking step (v7.5-phase6).
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-abandon-stale-runs.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/cast-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  # Provision schema via authoritative init script (provisions agent_runs + sessions)
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# --- agent_runs (existing behaviour) ---

@test "exits 0 when DB does not exist" {
  export CAST_DB_PATH="/nonexistent/path/no-cast.db"
  run python3 "$SCRIPT"
  assert_success
}

@test "exits 0 and logs nothing when no stale running rows" {
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('bot','running', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  run python3 "$SCRIPT"
  assert_success
  # Fresh row should NOT be abandoned
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE status='abandoned';")
  [ "$count" -eq 0 ]
}

@test "abandons agent_run stuck in running beyond threshold" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('bot','running','$old_ts');"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE status='abandoned';")
  [ "$count" -eq 1 ]
}

# --- C3 fix (2026-08-18): reaped rows must carry an explicit no-response marker,
# not NULL, so they're distinguishable from a DONE run with a legitimately-empty
# response. See plans/c2-c3-response-loss-findings.md. ---

@test "abandoned agent_run gets an explicit no-response marker, not NULL" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('bot','running','$old_ts');"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE status='abandoned';")
  [ -n "$response" ]
  [[ "$response" == *"SubagentStop never fired"* ]]
}

@test "abandon never clobbers a response that is already populated" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, response) VALUES ('bot','running','$old_ts','real response text');"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE status='abandoned';")
  [ "$response" = "real response text" ]
}

# --- sessions crash-marking (new behaviour, v7.5-phase6) ---

@test "flips stale active session to crashed" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO sessions (id, status, started_at) VALUES ('sess-stale','active','$old_ts');"
  export CAST_SESSION_CRASH_HOURS=4
  run python3 "$SCRIPT"
  assert_success
  status=$(sqlite3 "$TEST_DB" "SELECT status FROM sessions WHERE id='sess-stale';")
  [ "$status" = "crashed" ]
}

@test "does not flip fresh active session" {
  # Session started just now — well within the 4h threshold
  sqlite3 "$TEST_DB" "INSERT INTO sessions (id, status, started_at) VALUES ('sess-fresh','active',strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  export CAST_SESSION_CRASH_HOURS=4
  run python3 "$SCRIPT"
  assert_success
  status=$(sqlite3 "$TEST_DB" "SELECT status FROM sessions WHERE id='sess-fresh';")
  [ "$status" = "active" ]
}

@test "does not flip already-ended session" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=6)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO sessions (id, status, started_at) VALUES ('sess-ended','ended','$old_ts');"
  export CAST_SESSION_CRASH_HOURS=4
  run python3 "$SCRIPT"
  assert_success
  status=$(sqlite3 "$TEST_DB" "SELECT status FROM sessions WHERE id='sess-ended';")
  [ "$status" = "ended" ]
}

# --- incident emission (LF-4: INCIDENT-BLIND fix) ---

@test "reaped stale run inserts one incidents row with correct surfaced_by and resolution_status" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('reaper-bot','running','$old_ts');"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  inc_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents WHERE surfaced_by='stale-run-reaper';")
  [ "$inc_count" -eq 1 ]
  res_status=$(sqlite3 "$TEST_DB" "SELECT resolution_status FROM incidents WHERE surfaced_by='stale-run-reaper';")
  [ "$res_status" = "open" ]
}

@test "no incidents row when nothing is stale" {
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('fresh-bot','running', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  run python3 "$SCRIPT"
  assert_success
  inc_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents WHERE surfaced_by='stale-run-reaper';")
  [ "$inc_count" -eq 0 ]
}

@test "reap still succeeds when incidents table is missing" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('bot-no-inc','running','$old_ts');"
  sqlite3 "$TEST_DB" "DROP TABLE IF EXISTS incidents;"
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  # agent_runs row must still be flipped despite missing incidents table
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE status='abandoned';")
  [ "$count" -eq 1 ]
}

# --- C4 fix (2026-08-18): recover partial output from the transcript at reap
# time, instead of just writing the "[NO RESPONSE ...]" marker. See
# recover_stale_responses() in cast-abandon-stale-runs.py. ---

# Plants a transcript file at the exact path/shape _resolve_transcript_path()
# globs for: ~/.claude/projects/<slug>/<session_id>/subagents/agent-<agent_id>.jsonl
_plant_transcript() {
  local session_id="$1"
  local agent_id="$2"
  local content="$3"
  local dir="$HOME/.claude/projects/proj-test/${session_id}/subagents"
  mkdir -p "$dir"
  printf '%s' "$content" > "${dir}/agent-${agent_id}.jsonl"
}

@test "recovers response text from a planted transcript ending in a text block" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('bot','running','$old_ts','aid-text','sess-text');"
  _plant_transcript "sess-text" "aid-text" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Partial work done before kill"}]}}
'
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-text';")
  [[ "$response" == "[PARTIAL — recovered from transcript; SubagentStop never fired] Partial work done before kill" ]]
}

@test "recovers a StructuredOutput tool_use in the [structured-output:...] shape" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('workflow-subagent','running','$old_ts','aid-so','sess-so');"
  _plant_transcript "sess-so" "aid-so" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"StructuredOutput","input":{"foo":"bar"}}]}}
'
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-so';")
  [[ "$response" == *"[PARTIAL — recovered from transcript; SubagentStop never fired] [structured-output:StructuredOutput]"* ]]
  [[ "$response" == *'"foo": "bar"'* ]]
}

@test "no transcript on disk degrades to the no-response marker, exit 0" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('bot','running','$old_ts','aid-missing','sess-missing');"
  # Deliberately no _plant_transcript call — no file exists at the resolved path.
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-missing';")
  [[ "$response" == "[NO RESPONSE"* ]]
  [[ "$response" != "[PARTIAL"* ]]
}

@test "backfills a row already flipped to 'failed' by a bash sweep carrying the marker" {
  # Simulates cast-maintenance.sh / cast-session-end.sh having already flipped
  # this row on a PRIOR run (or a different sweep) — status is already terminal
  # and it already carries the marker. This is the ordering hole: recovery must
  # be state-based, not tied to Step 1 flipping the row in THIS run.
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id, response) VALUES ('bot','failed', strftime('%Y-%m-%dT%H:%M:%SZ','now','-3 hours'), 'aid-backfill', 'sess-backfill', '[NO RESPONSE — SubagentStop never fired; reaped by cast-maintenance.sh after 2h stale running]');"
  _plant_transcript "sess-backfill" "aid-backfill" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Recovered via backfill"}]}}
'
  run python3 "$SCRIPT"
  assert_success
  status=$(sqlite3 "$TEST_DB" "SELECT status FROM agent_runs WHERE agent_id='aid-backfill';")
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-backfill';")
  [ "$status" = "failed" ]
  [[ "$response" == "[PARTIAL — recovered from transcript; SubagentStop never fired] Recovered via backfill" ]]
}

@test "recovery never clobbers a response that already holds real content" {
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id, response) VALUES ('bot','failed', strftime('%Y-%m-%dT%H:%M:%SZ','now','-3 hours'), 'aid-real', 'sess-real', 'a genuinely complete real response');"
  _plant_transcript "sess-real" "aid-real" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"this must NEVER overwrite the real response"}]}}
'
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-real';")
  [ "$response" = "a genuinely complete real response" ]
}

@test "malformed JSONL transcript degrades to the marker, exit 0, no crash" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('bot','running','$old_ts','aid-bad','sess-bad');"
  _plant_transcript "sess-bad" "aid-bad" 'not valid json at all
{ this is also broken json
'
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-bad';")
  [[ "$response" == "[NO RESPONSE"* ]]
}

@test "oversized transcript degrades to the marker instead of being read" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('bot','running','$old_ts','aid-big','sess-big');"
  _plant_transcript "sess-big" "aid-big" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"this line is well past the tiny byte cap set for this test"}]}}
'
  export CAST_ABANDON_STALE_HOURS=2
  export CAST_TRANSCRIPT_MAX_BYTES=10
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-big';")
  [[ "$response" == "[NO RESPONSE"* ]]
}

@test "running the reaper twice does not double-prefix an already-recovered row" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('bot','running','$old_ts','aid-idem','sess-idem');"
  _plant_transcript "sess-idem" "aid-idem" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"idempotency check"}]}}
'
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  first=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-idem';")
  run python3 "$SCRIPT"
  assert_success
  second=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-idem';")
  [ "$first" = "$second" ]
  [[ "$second" != *"[PARTIAL"*"[PARTIAL"* ]]
}

# --- text-preference fix (2026-08-18, same day as C4): the killed agent's
# LAST assistant message is almost always an ordinary tool_use (Bash, Edit,
# ...) — what it was mid-flight doing, not its work. Its actual partial
# report sits in an EARLIER text turn. These cases prove the walk prefers
# that text over any trailing tool call, and that a non-StructuredOutput
# terminal tool call never gets mislabeled with the structured-output tag. ---

@test "prose from an earlier turn wins over trailing tool_use-only turns" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('bash-specialist','running','$old_ts','aid-trailing','sess-trailing');"
  # Three separate assistant turns, oldest first: prose, then two turns that
  # are ONLY a tool_use (simulating the agent being killed mid-tool-call
  # after already reporting its progress in prose).
  _plant_transcript "sess-trailing" "aid-trailing" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Now re-apply the five consolidation edits cleanly to the restored original."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/foo.sh"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
'
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-trailing';")
  [[ "$response" == "[PARTIAL — recovered from transcript; SubagentStop never fired] Now re-apply the five consolidation edits cleanly to the restored original." ]]
  # The recovered text is the earlier prose, not either trailing tool call.
  [[ "$response" != *"last-tool-call"* ]]
  [[ "$response" != *"structured-output"* ]]
  [[ "$response" != *"git status"* ]]
}

@test "non-StructuredOutput terminal tool call with no text anywhere gets [last-tool-call:...], never [structured-output:...]" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('merge','running','$old_ts','aid-lasttool','sess-lasttool');"
  _plant_transcript "sess-lasttool" "aid-lasttool" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"git ls-remote origin main | head -1"}}]}}
'
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-lasttool';")
  [[ "$response" == *"[PARTIAL — recovered from transcript; SubagentStop never fired] [last-tool-call:Bash]"* ]]
  [[ "$response" == *"git ls-remote origin main"* ]]
  [[ "$response" != *"[structured-output:"* ]]
}

@test "transcript with no assistant messages at all falls back to the no-response marker" {
  old_ts=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at, agent_id, session_id) VALUES ('bot','running','$old_ts','aid-nouser','sess-nouser');"
  _plant_transcript "sess-nouser" "aid-nouser" '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}
'
  export CAST_ABANDON_STALE_HOURS=2
  run python3 "$SCRIPT"
  assert_success
  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent_id='aid-nouser';")
  [[ "$response" == "[NO RESPONSE"* ]]
  [[ "$response" != "[PARTIAL"* ]]
}
