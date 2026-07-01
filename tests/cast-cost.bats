#!/usr/bin/env bats
# Tests for cast cost subcommand (F1 cost-attribution, Unit 3)
# Covers: summary view, --by-agent, --by-branch, --by-task views, --project filtering, --json, --limit flags
# Regression guards: verifies ar.project bug (fixed in recent bin/cast) doesn't resurface

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  teardown_temp_home
}

# ───────────────────────────────────────────────────────────────────────────
# Helper: seed deterministic test data into agent_runs and sessions
# ───────────────────────────────────────────────────────────────────────────

_seed_test_data() {
  local db="$1"

  # Initialize schema (creates branch column, all token columns)
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed sessions WITH project column (for --project filtering tests)
  sqlite3 "$db" <<'SQL'
INSERT INTO sessions (id, project, started_at, ended_at)
VALUES
  ('sess-1', 'project-alpha', '2026-06-27T09:00:00Z', '2026-06-27T09:30:00Z'),
  ('sess-2', 'project-alpha', '2026-06-27T10:00:00Z', '2026-06-27T10:30:00Z'),
  ('sess-3', 'project-beta', '2026-06-27T11:00:00Z', '2026-06-27T11:30:00Z');
SQL

  # Seed agent_runs with deterministic costs and tokens
  sqlite3 "$db" <<'SQL'
INSERT INTO agent_runs (
  session_id, agent, started_at, ended_at, status,
  input_tokens, output_tokens, cost_usd,
  cache_read_input_tokens, cache_creation_input_tokens,
  branch
) VALUES
  ('sess-1', 'code-writer', '2026-06-27T09:00:00Z', '2026-06-27T09:05:00Z', 'DONE',
   100, 50, 1.00,
   900, 0,
   'feature/x'),

  ('sess-1', 'code-reviewer', '2026-06-27T09:05:00Z', '2026-06-27T09:10:00Z', 'DONE',
   50, 25, 2.00,
   450, 0,
   'feature/x'),

  ('sess-2', 'code-writer', '2026-06-27T10:00:00Z', '2026-06-27T10:05:00Z', 'DONE',
   200, 100, 4.00,
   0, 0,
   NULL),

  ('sess-2', 'debugger', '2026-06-27T10:05:00Z', '2026-06-27T10:10:00Z', 'DONE',
   150, 75, 1.50,
   600, 100,
   NULL),

  ('sess-3', 'code-writer', '2026-06-27T11:00:00Z', '2026-06-27T11:05:00Z', 'DONE',
   80, 40, 0.80,
   320, 0,
   'feature/y');
SQL
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION A: Summary view (default, no --by-* flag)
# ───────────────────────────────────────────────────────────────────────────

@test "cast cost (summary): runs successfully and prints Total with exact cost sum" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost

  assert_success
  # Total cost: 1.00 + 2.00 + 4.00 + 1.50 + 0.80 = 9.30
  assert_output --partial "Total: \$9.30"
}

@test "cast cost (summary): calculates cache-read share correctly" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost

  assert_success
  # Totals:
  #   input_tokens = 100 + 50 + 200 + 150 + 80 = 580
  #   cache_read = 900 + 450 + 0 + 600 + 320 = 2270
  #   cache_write = 0 + 0 + 0 + 100 + 0 = 100
  #   input_side = 580 + 100 + 2270 = 2950
  #   cache_read_share = 2270 / 2950 * 100 = 76.9%
  assert_output --partial "Cache-read share of input-side tokens: 76.9%"
}

@test "cast cost (summary): shows all token columns" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost

  assert_success
  assert_output --partial "Input:"
  assert_output --partial "Output:"
  assert_output --partial "Cache-read:"
  assert_output --partial "Cache-write:"
}

@test "cast cost (summary): displays period range" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost

  assert_success
  assert_output --partial "Period:"
  assert_output --partial "2026-06-27"
}

@test "cast cost (summary): --json emits valid JSON structure" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --json

  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert 'period' in data and 'first' in data['period']
assert 'total_cost_usd' in data and data['total_cost_usd'] == 9.30
assert 'cache_read_share_pct' in data
assert 'tokens' in data
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION B: --by-agent view
# ───────────────────────────────────────────────────────────────────────────

@test "cast cost --by-agent: groups cost by agent name" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-agent

  assert_success
  assert_output --partial "code-writer"
  assert_output --partial "code-reviewer"
  assert_output --partial "debugger"
}

@test "cast cost --by-agent: sums costs per agent correctly" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-agent

  assert_success
  # code-writer: 1.00 + 4.00 + 0.80 = 5.80
  # code-reviewer: 2.00
  # debugger: 1.50
  local pos_writer pos_reviewer pos_debugger
  pos_writer=$(printf '%s\n' "$output" | grep -n "code-writer" | head -1 | cut -d: -f1)
  pos_reviewer=$(printf '%s\n' "$output" | grep -n "code-reviewer" | head -1 | cut -d: -f1)
  pos_debugger=$(printf '%s\n' "$output" | grep -n "debugger" | head -1 | cut -d: -f1)
  [ -n "$pos_writer" ] && [ -n "$pos_reviewer" ] && [ -n "$pos_debugger" ]
  [ "$pos_writer" -lt "$pos_reviewer" ]
  [ "$pos_writer" -lt "$pos_debugger" ]
}

@test "cast cost --by-agent --json: emits valid JSON array" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-agent --json

  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['view'] == 'by_agent'
assert len(data['rows']) == 3
assert data['rows'][0]['agent'] == 'code-writer'
assert data['rows'][0]['cost_usd'] == 5.80
print('OK')
" "$output"
  assert_success
}

@test "cast cost --by-agent: counts runs per agent" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-agent

  assert_success
  local line
  line=$(printf '%s\n' "$output" | grep "code-writer" | head -1)
  echo "$line" | grep -qE '[[:space:]]3[[:space:]]*$'
}

@test "cast cost --by-agent --limit 1: caps results to N rows" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-agent --limit 1

  assert_success
  assert_output --partial "code-writer"
  refute_output --partial "code-reviewer"
  refute_output --partial "debugger"
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION C: --by-branch view
# ───────────────────────────────────────────────────────────────────────────

@test "cast cost --by-branch: groups cost by branch with NULL → (pre-capture)" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-branch

  assert_success
  assert_output --partial "feature/x"
  assert_output --partial "feature/y"
  assert_output --partial "(pre-capture)"
}

@test "cast cost --by-branch: sums costs per branch correctly" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-branch

  assert_success
  # feature/x: 1.00 + 2.00 = 3.00
  # feature/y: 0.80
  # (pre-capture): 4.00 + 1.50 = 5.50
  local pos_precap pos_x pos_y
  pos_precap=$(printf '%s\n' "$output" | grep -n "(pre-capture)" | head -1 | cut -d: -f1)
  pos_x=$(printf '%s\n' "$output" | grep -n "feature/x" | head -1 | cut -d: -f1)
  pos_y=$(printf '%s\n' "$output" | grep -n "feature/y" | head -1 | cut -d: -f1)
  [ -n "$pos_precap" ] && [ -n "$pos_x" ] && [ -n "$pos_y" ]
  [ "$pos_precap" -lt "$pos_x" ] && [ "$pos_x" -lt "$pos_y" ]
}

@test "cast cost --by-branch --json: emits valid JSON with branch_capture_active flag" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-branch --json

  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['branch_capture_active'] == True
assert len(data['rows']) == 3
branches = [r['branch'] for r in data['rows']]
assert '(pre-capture)' in branches
print('OK')
" "$output"
  assert_success
}

@test "cast cost --by-branch: inactive branch capture (no branch column) returns advisory" {
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY, session_id TEXT, agent TEXT, cost_usd REAL);
INSERT INTO agent_runs VALUES (1, 's1', 'agent-x', 1.00);
SQL

  run bash "$CAST_BIN" cost --by-branch

  assert_success
  assert_output --partial "branch attribution is not active"
}

@test "cast cost --by-branch --limit 1: shows only highest cost branch" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-branch --limit 1

  assert_success
  assert_output --partial "(pre-capture)"
  refute_output --partial "feature/x"
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION D: --by-task view (group by session)
# ───────────────────────────────────────────────────────────────────────────

@test "cast cost --by-task: groups cost by session" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-task

  assert_success
  assert_output --partial "2026-06-27"
}

@test "cast cost --by-task: shows session cost and run count ordered by cost DESC" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-task

  assert_success
  # sess-2 (5.50) should appear before sess-1 (3.00)
  # Output shows: $     5.50      2  project-alpha · 2026-06-27 · sess-2
  local pos_s2 pos_s1
  pos_s2=$(printf '%s\n' "$output" | grep -n "sess-2" | head -1 | cut -d: -f1)
  pos_s1=$(printf '%s\n' "$output" | grep -n "sess-1" | head -1 | cut -d: -f1)
  [ -n "$pos_s2" ] && [ -n "$pos_s1" ] && [ "$pos_s2" -lt "$pos_s1" ]
}

@test "cast cost --by-task --json: emits valid JSON with session details" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-task --json

  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['view'] == 'by_task'
assert len(data['rows']) == 3
for r in data['rows']:
  assert 'session_id' in r and 'cost_usd' in r and 'label' in r
assert data['rows'][0]['cost_usd'] == 5.50  # sess-2
assert data['rows'][1]['cost_usd'] == 3.00  # sess-1
print('OK')
" "$output"
  assert_success
}

@test "cast cost --by-task --limit 2: shows only top 2 sessions" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-task --limit 2

  assert_success
  # Should show sess-2 and sess-1 but not sess-3
  assert_output --partial "sess-2"
  assert_output --partial "sess-1"
  refute_output --partial "sess-3"
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION E: --project filtering (regression guard for ar.project bug)
# ───────────────────────────────────────────────────────────────────────────

@test "cast cost --project alpha: filters summary to project-alpha (1.00 + 2.00 + 4.00 + 1.50 = 8.50)" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --project project-alpha

  assert_success
  assert_output --partial "Total: \$8.50"
}

@test "cast cost --project beta: filters summary to project-beta (0.80)" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --project project-beta

  assert_success
  assert_output --partial "Total: \$0.80"
}

@test "cast cost --project nonexistent: returns zero cost without crashing" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --project nonexistent-project

  assert_success
  assert_output --partial "Total: \$0.00"
}

@test "cast cost --by-task --project alpha: filters to alpha sessions only" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-task --project project-alpha

  assert_success
  # Should show sess-1 (3.00) and sess-2 (5.50) but NOT sess-3 (0.80)
  assert_output --partial "sess-1"
  assert_output --partial "sess-2"
  refute_output --partial "sess-3"
}

@test "cast cost --by-task --project beta: filters to beta sessions only" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-task --project project-beta

  assert_success
  # Should show only sess-3
  assert_output --partial "sess-3"
  refute_output --partial "sess-1"
  refute_output --partial "sess-2"
}

@test "cast cost --project alpha --json: summary view includes project_filter key" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --project project-alpha --json

  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data.get('project_filter') == 'project-alpha'
assert data['total_cost_usd'] == 8.50  # sum of project-alpha costs
print('OK')
" "$output"
  assert_success
}

@test "cast cost --project nonexistent --json: returns valid JSON with zero cost" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --project nonexistent --json

  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['total_cost_usd'] == 0.0
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION F: Edge cases and combined flags
# ───────────────────────────────────────────────────────────────────────────

@test "cast cost (summary): empty database returns zero totals" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  run bash "$CAST_BIN" cost

  assert_success
  assert_output --partial "Total: \$0.00"
}

@test "cast cost --json: output is valid JSON that can be re-parsed" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --json

  assert_success
  run python3 -c "
import sys, json
data1 = json.loads(sys.argv[1])
data2 = json.loads(json.dumps(data1))
assert data1 == data2
print('OK')
" "$output"
  assert_success
}

@test "cast cost --by-agent --by-project: NEVER uses ar.project (regression guard)" {
  _seed_test_data "$CAST_DB_PATH"

  run bash "$CAST_BIN" cost --by-agent --project project-alpha

  # Should succeed without OperationalError (ar.project doesn't exist)
  assert_success
  assert_output --partial "code-writer"
}
