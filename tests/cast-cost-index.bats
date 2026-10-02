#!/usr/bin/env bats
# Audit P-1 remainder / P-4b: date predicates on started_at must be index-friendly
# half-open ISO-T/Z ranges (not datetime()/replace() wrapped), with identical
# window semantics; `cast predict` must bound its routing_events read.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"
ISO="%Y-%m-%dT%H:%M:%SZ"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/config" "$HOME/.claude/agents" "$HOME/fake-repo" "$HOME/.claude/cast/events"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CLAUDE_SUBPROCESS=0
  export CAST_AGENTS_DIR="$HOME/.claude/agents"
  export CAST_REPO_DIR="$HOME/fake-repo"
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
}

teardown() {
  teardown_temp_home
}

# _ts <sqlite-modifier>  -> ISO-T/Z timestamp relative to now
_ts() { sqlite3 "$CAST_DB_PATH" "SELECT strftime('$ISO','now','$1');"; }

_plan() { sqlite3 "$CAST_DB_PATH" "EXPLAIN QUERY PLAN $1"; }

# ── EXPLAIN QUERY PLAN: converted predicates SEARCH via index ──────────────────

@test "plan: depth-cap predicate uses idx_agent_runs_started_at" {
  run _plan "SELECT COALESCE(SUM(spawn_depth > 1),0) FROM agent_runs WHERE spawn_depth IS NOT NULL AND started_at >= strftime('$ISO','now','-7 days');"
  assert_output --partial "SEARCH agent_runs USING INDEX idx_agent_runs_started_at"
  refute_output --partial "SCAN"
}

@test "plan: crashed-sessions predicate uses idx_sessions_started_at" {
  run _plan "SELECT COUNT(*) FROM sessions WHERE status='crashed' AND started_at >= strftime('$ISO','now','-7 days');"
  assert_output --partial "USING INDEX idx_sessions_started_at"
  refute_output --partial "SCAN"
}

@test "plan: cost-summary MIN(started_at) and prune predicate SEARCH the started_at index" {
  run _plan "SELECT date(MIN(started_at)) FROM agent_runs;"
  assert_output --regexp "SEARCH agent_runs USING (COVERING )?INDEX idx_agent_runs_started_at"
  run _plan "SELECT COUNT(*) FROM agent_runs WHERE started_at < strftime('$ISO','now','-30 days');"
  assert_output --regexp "SEARCH agent_runs USING (COVERING )?INDEX idx_agent_runs_started_at"
}

@test "plan: predict read is ordered by the timestamp index with a LIMIT" {
  run _plan "SELECT session_id, prompt_preview FROM routing_events WHERE prompt_preview IS NOT NULL AND prompt_preview != '' ORDER BY timestamp DESC LIMIT 10000"
  assert_output --partial "idx_routing_events_timestamp"
  refute_output --partial "USE TEMP B-TREE"
}

# ── behaviour through the real binary: window boundaries ──────────────────────

_depth_line() {
  run bash -c "bash '$CAST_BIN' doctor 2>&1 | grep 'subagent depth cap:'"
}

@test "doctor depth-cap: window is 7d - rows 1s inside count, 1s outside do not" {
  local inside outside
  inside="$(sqlite3 "$CAST_DB_PATH" "SELECT strftime('$ISO','now','-7 days','+60 seconds');")"
  outside="$(sqlite3 "$CAST_DB_PATH" "SELECT strftime('$ISO','now','-7 days','-60 seconds');")"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, started_at, spawn_depth) VALUES ('a','$inside',1),('b','$outside',2),('c','$(_ts '-1 hours')',1);"
  _depth_line
  # reference (old expression, inlined): same answer
  ref="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(spawn_depth) FROM agent_runs WHERE spawn_depth IS NOT NULL AND datetime(replace(replace(started_at,'T',' '),'Z','')) >= datetime('now','-7 day');")"
  [ "$ref" = "2" ]
  assert_output --partial "2 run(s) in last 7d, max depth 1"
}

@test "doctor crashed-sessions: window is 7d - boundary rows counted like the old expression" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO sessions (id, started_at, status) VALUES
    ('in1', strftime('$ISO','now','-7 days','+60 seconds'), 'crashed'),
    ('out1', strftime('$ISO','now','-7 days','-60 seconds'), 'crashed'),
    ('now1', strftime('$ISO','now','-1 hours'), 'crashed'),
    ('ok1', strftime('$ISO','now','-1 hours'), 'completed');"
  ref="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM sessions WHERE status='crashed' AND replace(replace(started_at,'T',' '),'Z','') >= datetime('now','-7 days');")"
  [ "$ref" = "2" ]
  run bash -c "bash '$CAST_BIN' doctor 2>&1 | grep 'crashed-sessions:'"
  assert_output --partial "crashed-sessions: 2 in last 7d"
}

@test "cost summary: Period first/last date come from MIN/MAX started_at (day boundary preserved)" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, started_at, status, cost_usd) VALUES
    ('a','2026-03-01T23:59:59Z','DONE',1),('b','2026-03-02T00:00:00Z','DONE',1),('c','2026-03-05T12:00:00Z','DONE',1);"
  run bash "$CAST_BIN" cost
  assert_output --partial "Period: 2026-03-01 → 2026-03-05"
}

@test "predict: reads only the most recent 10000 routing_events (older row excluded)" {
  sqlite3 "$CAST_DB_PATH" "
    INSERT INTO routing_events (session_id, timestamp, prompt_preview)
      VALUES ('old-sess','2020-01-01T00:00:00Z','zzqxuniqueoldkeyword task');
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 10000)
      INSERT INTO routing_events (session_id, timestamp, prompt_preview)
      SELECT 's' || i, strftime('$ISO','now','-' || i || ' seconds'), 'filler prompt text' FROM n;"
  run bash "$CAST_BIN" predict "zzqxuniqueoldkeyword" --json
  assert_output --partial '"sessions_searched": 10000'
}

# ── cast tidy prune: non-ISO started_at is KEPT, count matches delete ─────────

@test "tidy prune: 40d ISO row deleted, 40d space-format row survives, count is 1" {
  mkdir -p "$HOME/.claude/scripts"
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$HOME/.claude/scripts/cast-db-backup.py"
  export CAST_SCRIPTS_DIR="$HOME/.claude/scripts"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, started_at) VALUES
    ('iso-old', strftime('$ISO','now','-40 days')),
    ('space-old', strftime('%Y-%m-%d %H:%M:%S','now','-40 days'));"
  run bash "$CAST_BIN" tidy
  [ "$status" -eq 0 ]
  assert_output --regexp "DB agent_runs \(>30 days\) +pruned +1"
  [ "$(sqlite3 "$CAST_DB_PATH" "SELECT group_concat(agent) FROM agent_runs;")" = "space-old" ]
}

@test "plan: tidy prune predicate still SEARCHes idx_agent_runs_started_at with the GLOB" {
  run _plan "SELECT COUNT(*) FROM agent_runs WHERE started_at < strftime('$ISO','now','-30 days') AND started_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*';"
  assert_output --regexp "SEARCH agent_runs USING (COVERING )?INDEX idx_agent_runs_started_at"
}
