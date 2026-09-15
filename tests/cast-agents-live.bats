#!/usr/bin/env bats
# Tests for `cast agents --live` (v10 reliability: distinguish working from dead agents)
# Covers:
#   1. Filters on status='running' (excludes DONE rows), not a general dump
#   2. Threshold discriminates: old row flagged 'likely stuck', fresh row is not
#   3. Elapsed is genuinely computed (not frozen/hardcoded)
#   4. Human table drops TOOL USES/BRANCH (always NULL on the running path —
#      see bin/cast comment above the query); never prints 'None'
#   5. Zero running rows -> exact honest message, exit 0
#   6. --json emits valid JSON with expected view + real booleans
#   7. REGRESSION GUARD: NULL tool_uses/branch/model (the real recorder shape
#      for a running row) still renders a usable human table
#   8. --json still carries the raw (null) tool_uses field for machine consumers

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# ───────────────────────────────────────────────────────────────────────────
# Setup / Teardown — isolated temp HOME per test (HARD RULE — never real $HOME)
# ───────────────────────────────────────────────────────────────────────────

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  teardown_temp_home
}

# ───────────────────────────────────────────────────────────────────────────
# Helper: initialize schema + seed agent_runs with started_at RELATIVE TO NOW
#
# backend-writer__fresh   running, started ~2 min ago  (should NOT be flagged)
# code-reviewer__stale    running, started ~45 min ago (SHOULD be flagged)
# frontend-writer__done   DONE,    started ~5 min ago  (must be excluded)
# ───────────────────────────────────────────────────────────────────────────

_seed() {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" <<'SQL'
-- Running rows carry NULL tool_uses/branch/model — those are written on the completion path.
-- Measured 0/84 populated for non-DONE rows over 30d. A fixture with values here would be
-- a shape production never produces, and would hide dead-column defects (see v10 0.2).
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-1', 'backend-writer__fresh', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-2 minutes')), NULL, 'running', NULL, NULL, NULL, NULL, NULL),
  ('sess-1', 'code-reviewer__stale', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-45 minutes')), NULL, 'running', NULL, NULL, NULL, NULL, NULL),
  ('sess-1', 'frontend-writer__done', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-5 minutes')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-3 minutes')), 'DONE', 8, 120000, 'feature/v10-reliability', 'sonnet', 'done body');
SQL
}

# ───────────────────────────────────────────────────────────────────────────
# 1. Filters on status='running', excludes DONE
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: lists running agents, excludes DONE" {
  _seed
  run bash "$CAST_BIN" agents --live
  assert_success
  assert_output --partial 'backend-writer__fresh'
  assert_output --partial 'code-reviewer__stale'
  refute_output --partial 'frontend-writer__done'
}

# ───────────────────────────────────────────────────────────────────────────
# 2. Threshold discriminates: stale flagged, fresh not
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: flags the ~45min row 'likely stuck', not the ~2min row" {
  _seed
  run bash "$CAST_BIN" agents --live
  assert_success
  local stale_line fresh_line
  stale_line=$(printf '%s\n' "$output" | grep 'code-reviewer__stale')
  fresh_line=$(printf '%s\n' "$output" | grep 'backend-writer__fresh')
  [[ "$stale_line" == *"likely stuck"* ]]
  [[ "$fresh_line" != *"likely stuck"* ]]
}

# ───────────────────────────────────────────────────────────────────────────
# 3. Elapsed is really computed, not frozen
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: elapsed for the stale row is a large value, not ~2 minutes" {
  _seed
  run bash "$CAST_BIN" agents --live
  assert_success
  local stale_line
  stale_line=$(printf '%s\n' "$output" | grep 'code-reviewer__stale')
  # ~45min row must show at least a double-digit minute count or an hour marker —
  # never the same "2m0Xs" shape the fresh row would show.
  [[ "$stale_line" =~ (4[0-9]m|[0-9]+h) ]]
  [[ "$stale_line" != *"2m0"* ]]
}

# ───────────────────────────────────────────────────────────────────────────
# 4. Human table drops the dead TOOL USES/BRANCH columns, never prints 'None'
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: human table has no TOOL USES header and never prints None" {
  _seed
  run bash "$CAST_BIN" agents --live
  assert_success
  refute_output --partial 'TOOL USES'
  refute_output --partial 'BRANCH'
  refute_output --partial 'None'
}

# ───────────────────────────────────────────────────────────────────────────
# 5. Zero running rows -> honest exact message
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: no running agents prints exact honest message, exit 0" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  run bash "$CAST_BIN" agents --live
  assert_success
  assert_output 'No agents currently running.'
}

# ───────────────────────────────────────────────────────────────────────────
# 6. --json structure + real booleans
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live --json: valid JSON, view=agents_live, likely_stuck is a real bool" {
  _seed
  run bash "$CAST_BIN" agents --live --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['view'] == 'agents_live', 'wrong view: ' + str(data.get('view'))
rows = {r['agent']: r for r in data['rows']}
assert 'backend-writer__fresh' in rows, 'fresh row missing'
assert 'code-reviewer__stale' in rows, 'stale row missing'
assert 'frontend-writer__done' not in rows, 'DONE row leaked into --live output'
assert rows['code-reviewer__stale']['likely_stuck'] is True, 'stale row not flagged true'
assert rows['backend-writer__fresh']['likely_stuck'] is False, 'fresh row wrongly flagged true'
assert rows['code-reviewer__stale']['tool_uses'] is None, 'NULL tool_uses should serialize as JSON null'
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# 7. REGRESSION GUARD — the real recorder shape (NULL tool_uses/branch/model
#    on a running row) must still render a usable human table. This documents
#    the measured reality (0/84 non-DONE rows populated over a 30-day window)
#    so a future well-meaning change doesn't re-add a column that can never
#    hold a value on this path.
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: REGRESSION GUARD — NULL tool_uses/branch/model still renders agent + elapsed" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-2', 'backend-writer__no-recorder-fields', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-3 minutes')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL
  run bash "$CAST_BIN" agents --live
  assert_success
  assert_output --partial 'backend-writer__no-recorder-fields'
  # Real elapsed value present (a "Nm" or "Nh" shape), not a placeholder.
  [[ "$output" =~ backend-writer__no-recorder-fields[[:space:]]+[0-9]+m[0-9]+s ]]
  refute_output --partial 'None'
}

# ───────────────────────────────────────────────────────────────────────────
# 8. --json still carries the raw tool_uses field (null) for machine consumers
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live --json: tool_uses key present and null for a running row" {
  _seed
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-3', 'debugger__no-branch-model', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-1 minutes')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL
  run bash "$CAST_BIN" agents --live --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
rows = {r['agent']: r for r in data['rows']}
assert 'tool_uses' in rows['code-reviewer__stale'], 'tool_uses key missing from JSON row'
assert rows['code-reviewer__stale']['tool_uses'] is None, 'tool_uses should be JSON null, not omitted'
assert 'debugger__no-branch-model' in rows, 'NULL branch/model row missing from JSON output'
row = rows['debugger__no-branch-model']
assert 'branch' in row, 'branch key missing from JSON row'
assert row['branch'] is None, 'branch should be JSON null (not the \'?\' display placeholder) when unset, got: ' + repr(row['branch'])
assert 'model' in row, 'model key missing from JSON row'
assert row['model'] is None, 'model should be JSON null (not the \'?\' display placeholder) when unset, got: ' + repr(row['model'])
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# 9. Insurance: if the recorder ever DOES populate branch/model mid-run,
#    --json must pass those values through unchanged (not null, not '?').
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live --json: non-null branch/model pass through unchanged if ever populated" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-4', 'backend-writer__mid-run-populated', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-4 minutes')), NULL, 'running', NULL, NULL, 'feature/v10-reliability', 'sonnet', NULL);
SQL
  run bash "$CAST_BIN" agents --live --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
rows = {r['agent']: r for r in data['rows']}
assert 'backend-writer__mid-run-populated' in rows, 'populated row missing from JSON output'
row = rows['backend-writer__mid-run-populated']
assert row['branch'] == 'feature/v10-reliability', 'branch should pass through unchanged, got: ' + repr(row['branch'])
assert row['model'] == 'sonnet', 'model should pass through unchanged, got: ' + repr(row['model'])
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# 10. Per-agent baseline: bidirectional bug fix (v10 reliability)
#
# The old flat 600s threshold is wrong in both directions:
#   Direction A: a HIGH-baseline agent's normal ~700s run got flagged (it
#                shouldn't have been — its own p95 is 795s).
#   Direction B: a LOW-baseline agent hanging at 300s was NEVER flagged
#                (under the flat 600s), though it is already 3x its own p95.
# ───────────────────────────────────────────────────────────────────────────

_seed_baseline_done_rows() {
  local agent="$1" duration_ms="$2" count="$3"
  local i=1
  while [ "$i" -le "$count" ]; do
    sqlite3 "$CAST_DB_PATH" <<SQL
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-base-$i', '$agent', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-$i days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-$i days', '+10 minutes')), 'DONE', 5, $duration_ms, 'main', 'sonnet', 'done body');
SQL
    i=$((i + 1))
  done
}

@test "cast agents --live: Direction A — high-baseline agent at 700s is NOT flagged (old flat 600s would flag it)" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  _seed_baseline_done_rows 'backend-writer__highbase' 795000 5
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-run-a', 'backend-writer__highbase', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-700 seconds')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL
  run bash "$CAST_BIN" agents --live
  assert_success
  local line
  line=$(printf '%s\n' "$output" | grep 'backend-writer__highbase')
  [[ "$line" != *"stuck"* ]]
  [[ "$line" != *"⚠"* ]]
}

@test "cast agents --live: Direction B — low-baseline agent at 300s IS flagged (old flat 600s would NEVER catch this)" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  _seed_baseline_done_rows 'commit__lowbase' 95000 5
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-run-b', 'commit__lowbase', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-300 seconds')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL
  run bash "$CAST_BIN" agents --live
  assert_success
  local line
  line=$(printf '%s\n' "$output" | grep 'commit__lowbase')
  [[ "$line" == *"⚠"* ]]
}

@test "cast agents --live: agent with only 4 DONE runs (below n>=5 minimum) falls back to the flat 600s threshold" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  _seed_baseline_done_rows 'test-writer__fewbase' 50000 4
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-run-c', 'test-writer__fewbase', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-660 seconds')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL
  run bash "$CAST_BIN" agents --live --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
rows = {r['agent']: r for r in data['rows']}
row = rows['test-writer__fewbase']
assert row['baseline_n'] == 0, 'expected no qualifying baseline (only 4 runs), got baseline_n=' + repr(row['baseline_n'])
assert row['baseline_p95_seconds'] is None, 'expected null baseline_p95_seconds, got ' + repr(row['baseline_p95_seconds'])
assert row['threshold_seconds'] == 600, 'expected flat 600s fallback threshold, got ' + repr(row['threshold_seconds'])
assert row['likely_stuck'] is True, 'elapsed ~660s should exceed the 600s fallback'
print('OK')
" "$output"
  assert_success
}

@test "cast agents --live --json: carries baseline_p95_seconds, baseline_n, threshold_seconds; likely_stuck stays a real bool" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  _seed_baseline_done_rows 'backend-writer__highbase' 795000 5
  _seed_baseline_done_rows 'commit__lowbase' 95000 5
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-run-d1', 'backend-writer__highbase', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-700 seconds')), NULL, 'running', NULL, NULL, NULL, NULL, NULL),
  ('sess-run-d2', 'commit__lowbase', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-300 seconds')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL
  run bash "$CAST_BIN" agents --live --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
rows = {r['agent']: r for r in data['rows']}

high = rows['backend-writer__highbase']
assert isinstance(high['likely_stuck'], bool), 'likely_stuck must be a real bool'
assert high['likely_stuck'] is False, 'high-baseline 700s run should NOT be flagged'
assert high['baseline_n'] == 5, 'expected baseline_n=5, got ' + repr(high['baseline_n'])
assert abs(high['baseline_p95_seconds'] - 795.0) < 1, 'expected baseline_p95_seconds ~=795.0, got ' + repr(high['baseline_p95_seconds'])
assert abs(high['threshold_seconds'] - 1192.5) < 1, 'expected threshold_seconds ~=1192.5 (795*1.5), got ' + repr(high['threshold_seconds'])

low = rows['commit__lowbase']
assert isinstance(low['likely_stuck'], bool), 'likely_stuck must be a real bool'
assert low['likely_stuck'] is True, 'low-baseline 300s run SHOULD be flagged'
assert low['baseline_n'] == 5, 'expected baseline_n=5, got ' + repr(low['baseline_n'])
assert abs(low['baseline_p95_seconds'] - 95.0) < 1, 'expected baseline_p95_seconds ~=95.0, got ' + repr(low['baseline_p95_seconds'])
assert abs(low['threshold_seconds'] - 142.5) < 1, 'expected threshold_seconds ~=142.5 (max(95*1.5,120)), got ' + repr(low['threshold_seconds'])
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# 11. NTILE(20) degeneracy: n<20 must label itself 'max', never 'p95'
#
# NTILE(20) needs >=20 rows per agent to produce a genuine 95th percentile.
# With fewer rows every row lands in its own bucket, so "b<=19" excludes
# nothing and MAX(...) returns the true maximum, not a p95. A fixture with
# IDENTICAL durations can't tell max from p95 (they're the same number) —
# this fixture uses six DIFFERING durations so the two statistics would
# diverge if the code (wrongly) computed a real percentile instead.
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: n=6 differing durations reports baseline_stat=max, not p95 (NTILE degeneracy)" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-ntile-1', 'bash-specialist__discovery-scope', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-1 days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-1 days', '+10 minutes')), 'DONE', 5, 100000, 'main', 'sonnet', 'done'),
  ('sess-ntile-2', 'bash-specialist__discovery-scope', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-2 days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-2 days', '+10 minutes')), 'DONE', 5, 200000, 'main', 'sonnet', 'done'),
  ('sess-ntile-3', 'bash-specialist__discovery-scope', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-3 days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-3 days', '+10 minutes')), 'DONE', 5, 300000, 'main', 'sonnet', 'done'),
  ('sess-ntile-4', 'bash-specialist__discovery-scope', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-4 days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-4 days', '+10 minutes')), 'DONE', 5, 400000, 'main', 'sonnet', 'done'),
  ('sess-ntile-5', 'bash-specialist__discovery-scope', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-5 days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-5 days', '+10 minutes')), 'DONE', 5, 500000, 'main', 'sonnet', 'done'),
  ('sess-ntile-6', 'bash-specialist__discovery-scope', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-6 days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-6 days', '+10 minutes')), 'DONE', 5, 600000, 'main', 'sonnet', 'done');
SQL
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-run-ntile', 'bash-specialist__discovery-scope', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-950 seconds')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL

  run bash "$CAST_BIN" agents --live --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
rows = {r['agent']: r for r in data['rows']}
row = rows['bash-specialist__discovery-scope']
assert row['baseline_n'] == 6, 'expected baseline_n=6, got ' + repr(row['baseline_n'])
assert row['baseline_stat'] == 'max', 'expected baseline_stat=max (n<20 NTILE degeneracy), got ' + repr(row['baseline_stat'])
assert abs(row['baseline_p95_seconds'] - 600.0) < 1, 'expected the baseline value ~=600.0 (the true max of 6 differing durations), got ' + repr(row['baseline_p95_seconds'])
print('OK')
" "$output"
  assert_success

  run bash "$CAST_BIN" agents --live
  assert_success
  local line
  line=$(printf '%s\n' "$output" | grep 'bash-specialist__discovery-scope')
  [[ "$line" == *"max (n=6)"* ]]
  [[ "$line" != *"p95"* ]]
}

# ───────────────────────────────────────────────────────────────────────────
# 12. NTILE(20) lower boundary: n=20 is the FIRST count where bucket 20 holds
# exactly the top row, so b<=19 excludes it and MAX(...) over that filtered
# set becomes a genuine 95th percentile, not the true max. n=19 is still
# degenerate (every row its own bucket); n=20 is the first genuine case.
# `b_n >= 20` is the load-bearing boundary in bin/cast — a fixture asserting
# only the n=6 (degenerate) side can't catch an off-by-N regression at this
# threshold (e.g. `>= 25` or `> 20`), so this fixture pins n=20 exactly, with
# 20 DIFFERING durations (identical durations make max and p95
# indistinguishable, which is why this couldn't have been the existing
# n=6 test).
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --live: exactly n=20 reports baseline_stat=p95 (lower boundary of the NTILE(20) genuine-percentile range)" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  local i sql_values=""
  for i in $(seq 1 20); do
    sql_values+="  ('sess-p95-$i', 'test-writer__n20boundary', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-$i days')), strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-$i days', '+10 minutes')), 'DONE', 5, $((i * 100000)), 'main', 'sonnet', 'done')"
    if [ "$i" -lt 20 ]; then
      sql_values+=$',\n'
    else
      sql_values+=$';\n'
    fi
  done
  sqlite3 "$CAST_DB_PATH" <<SQL
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
$sql_values
SQL
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-run-n20', 'test-writer__n20boundary', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-950 seconds')), NULL, 'running', NULL, NULL, NULL, NULL, NULL);
SQL

  run bash "$CAST_BIN" agents --live --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
rows = {r['agent']: r for r in data['rows']}
row = rows['test-writer__n20boundary']
assert row['baseline_n'] == 20, 'expected baseline_n=20, got ' + repr(row['baseline_n'])
assert row['baseline_stat'] == 'p95', 'expected baseline_stat=p95 at the n=20 lower boundary (genuine NTILE percentile), got ' + repr(row['baseline_stat'])
print('OK')
" "$output"
  assert_success
}
