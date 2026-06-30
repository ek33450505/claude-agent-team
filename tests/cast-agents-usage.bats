#!/usr/bin/env bats
# Tests for `cast agents --usage` subcommand (v9 F2 record→decision loop, Unit 2)
# Covers:
#   A. Text view with data: code-writer stats, sort order, avg cost $2.00, success 67%
#   B. JSON variant: view key, first-row agent/dispatches/success_rate/avg_cost_usd
#   C. Zero-rows: honest message (text) + empty rows array (JSON)
#   D. DB absent: exit non-zero + 'cast.db not found'
#   E. REGRESSION: no-flag listing unchanged — no DB required, no DISPATCHES header

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
  mkdir -p "$HOME/.claude/agents"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CAST_AGENTS_DIR="$HOME/.claude/agents"
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  teardown_temp_home
}

# ───────────────────────────────────────────────────────────────────────────
# Helper: initialize schema + seed deterministic agent_runs data
#
# code-writer:   3 rows (DONE/DONE/BLOCKED, costs 1.00/2.00/3.00)
#   → dispatches=3, avg_cost_usd=2.0000, success_rate=0.6667 (67%)
# code-reviewer: 1 row  (DONE, cost 0.50)
#   → dispatches=1, avg_cost_usd=0.5000, success_rate=1.0000 (100%)
# ───────────────────────────────────────────────────────────────────────────

_seed() {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, cost_usd)
VALUES
  ('sess-1', 'code-writer',   '2026-06-30T09:00:00Z', '2026-06-30T09:05:00Z', 'DONE',    1.00),
  ('sess-1', 'code-writer',   '2026-06-30T09:05:00Z', '2026-06-30T09:10:00Z', 'DONE',    2.00),
  ('sess-1', 'code-writer',   '2026-06-30T09:10:00Z', '2026-06-30T09:15:00Z', 'BLOCKED', 3.00),
  ('sess-1', 'code-reviewer', '2026-06-30T09:15:00Z', '2026-06-30T09:20:00Z', 'DONE',    0.50);
SQL
}

# ───────────────────────────────────────────────────────────────────────────
# A. Text view with data
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage: succeeds and shows code-writer" {
  _seed
  run bash "$CAST_BIN" agents --usage
  assert_success
  assert_output --partial 'code-writer'
}

@test "cast agents --usage: shows avg cost 2.00 for code-writer (3-row average)" {
  _seed
  run bash "$CAST_BIN" agents --usage
  assert_success
  # Output format is "$    2.00" (right-padded); match the value without the spacing
  assert_output --partial '2.00'
}

@test "cast agents --usage: shows 67% success rate for code-writer (2 of 3 DONE)" {
  _seed
  run bash "$CAST_BIN" agents --usage
  assert_success
  assert_output --partial '67%'
}

@test "cast agents --usage: code-writer appears before code-reviewer (sorted dispatch count desc)" {
  _seed
  run bash "$CAST_BIN" agents --usage
  assert_success
  local pos_writer pos_reviewer
  pos_writer=$(printf '%s\n' "$output" | grep -n 'code-writer' | head -1 | cut -d: -f1)
  pos_reviewer=$(printf '%s\n' "$output" | grep -n 'code-reviewer' | head -1 | cut -d: -f1)
  [ -n "$pos_writer" ]
  [ -n "$pos_reviewer" ]
  [ "$pos_writer" -lt "$pos_reviewer" ]
}

# ───────────────────────────────────────────────────────────────────────────
# B. JSON variant
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage --json: emits valid JSON with correct structure and values" {
  _seed
  run bash "$CAST_BIN" agents --usage --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['view'] == 'by_agent_usage', 'wrong view: ' + str(data.get('view'))
rows = data['rows']
assert rows[0]['agent'] == 'code-writer', 'wrong first agent: ' + rows[0]['agent']
assert rows[0]['dispatches'] == 3, 'wrong dispatches: ' + str(rows[0]['dispatches'])
assert rows[0]['success_rate'] == 0.6667, 'wrong success_rate: ' + str(rows[0]['success_rate'])
assert rows[0]['avg_cost_usd'] == 2.0, 'wrong avg_cost_usd: ' + str(rows[0]['avg_cost_usd'])
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# C. Zero-rows cases — honest output when DB is empty
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage: empty DB prints 'No agent runs recorded yet'" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  run bash "$CAST_BIN" agents --usage
  assert_success
  assert_output --partial 'No agent runs recorded yet'
}

@test "cast agents --usage --json: empty DB returns JSON with empty rows array" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  run bash "$CAST_BIN" agents --usage --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['view'] == 'by_agent_usage', 'wrong view: ' + str(data.get('view'))
assert data['rows'] == [], 'expected empty rows, got: ' + str(data['rows'])
print('OK')
" "$output"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# D. DB absent failure — informative error, non-zero exit
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage: exits non-zero with 'cast.db not found' when DB absent" {
  rm -f "$CAST_DB_PATH"
  run bash "$CAST_BIN" agents --usage
  assert_failure
  assert_output --partial 'cast.db not found'
}

# ───────────────────────────────────────────────────────────────────────────
# E. REGRESSION: no-flag listing unchanged — never touches cast.db
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents (no flag): lists installed agents and shows 'agents installed' footer" {
  cat > "$CAST_AGENTS_DIR/test-agent.md" <<'MD'
---
name: test-agent
model: sonnet
description: A test agent for regression
---
Test agent body.
MD
  run bash "$CAST_BIN" agents
  assert_success
  assert_output --partial 'agents installed'
  refute_output --partial 'DISPATCHES'
}
