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
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-1', 'backend-writer__fresh', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-2 minutes')), NULL, 'running', 12, NULL, 'feature/v10-reliability', 'sonnet', NULL),
  ('sess-1', 'code-reviewer__stale', strftime('%Y-%m-%dT%H:%M:%SZ', datetime('now', '-45 minutes')), NULL, 'running', NULL, NULL, 'feature/v10-reliability', 'sonnet', NULL),
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
