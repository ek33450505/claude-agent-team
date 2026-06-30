#!/usr/bin/env bats
# Tests for cast agents --usage subcommand (v9 F2 Unit 1)
# Covers: table output, --json, zero-rows honesty, DB-absent error, no-flag listing unchanged

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"

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
# Helper: initialize schema + seed agent_runs with deterministic data
# ───────────────────────────────────────────────────────────────────────────

_seed_usage_data() {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO sessions (id, project, started_at, ended_at)
VALUES
  ('sess-u1', 'test-proj', '2026-06-30T09:00:00Z', '2026-06-30T09:30:00Z'),
  ('sess-u2', 'test-proj', '2026-06-30T10:00:00Z', '2026-06-30T10:30:00Z');

-- code-writer: 3 dispatches, 2 DONE, 1 DONE_WITH_CONCERNS
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, cost_usd)
VALUES
  ('sess-u1', 'code-writer', '2026-06-30T09:00:00Z', '2026-06-30T09:05:00Z', 'DONE', 0.50),
  ('sess-u1', 'code-writer', '2026-06-30T09:10:00Z', '2026-06-30T09:15:00Z', 'DONE', 0.30),
  ('sess-u1', 'code-writer', '2026-06-30T09:20:00Z', '2026-06-30T09:25:00Z', 'DONE_WITH_CONCERNS', 0.20);

-- code-reviewer: 2 dispatches, both DONE
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, cost_usd)
VALUES
  ('sess-u2', 'code-reviewer', '2026-06-30T10:00:00Z', '2026-06-30T10:05:00Z', 'DONE', 0.10),
  ('sess-u2', 'code-reviewer', '2026-06-30T10:10:00Z', '2026-06-30T10:15:00Z', 'DONE', 0.10);

-- debugger: 1 dispatch, DONE
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, cost_usd)
VALUES
  ('sess-u2', 'debugger', '2026-06-30T10:20:00Z', '2026-06-30T10:25:00Z', 'DONE', 0.40);
SQL
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION A: Table output
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage: exits 0 and shows table header" {
  _seed_usage_data
  run bash "$CAST_CLI" agents --usage
  assert_success
  assert_output --partial "AGENT"
  assert_output --partial "DISPATCHES"
  assert_output --partial "AVG COST"
  assert_output --partial "SUCCESS"
}

@test "cast agents --usage: sorts by dispatch count descending" {
  _seed_usage_data
  run bash "$CAST_CLI" agents --usage
  assert_success
  # code-writer (3) should appear before code-reviewer (2) before debugger (1)
  [[ "$output" == *"code-writer"*"code-reviewer"*"debugger"* ]]
}

@test "cast agents --usage: shows correct dispatch counts" {
  _seed_usage_data
  run bash "$CAST_CLI" agents --usage
  assert_success
  # code-writer has 3 dispatches; the formatted number is "3" (no comma needed at this scale)
  assert_output --partial "code-writer"
  assert_output --partial "3"
}

@test "cast agents --usage: success rate for all-DONE agent is 100%" {
  _seed_usage_data
  run bash "$CAST_CLI" agents --usage
  assert_success
  # code-reviewer: 2/2 DONE → 100%
  assert_output --partial "100%"
}

@test "cast agents --usage: success rate for mixed-status agent is below 100%" {
  _seed_usage_data
  run bash "$CAST_CLI" agents --usage
  assert_success
  # code-writer: 2/3 DONE → 67%
  assert_output --partial "67%"
}

@test "cast agents --usage: shows footer with agent count" {
  _seed_usage_data
  run bash "$CAST_CLI" agents --usage
  assert_success
  assert_output --partial "agents with runtime data"
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION B: --json output
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage --json: exits 0 and emits valid JSON" {
  _seed_usage_data
  run bash "$CAST_CLI" --json agents --usage
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['view'] == 'by_agent_usage', f'expected by_agent_usage, got {d[\"view\"]}'
assert isinstance(d['rows'], list), 'rows must be a list'
assert len(d['rows']) == 3, f'expected 3 rows, got {len(d[\"rows\"])}'
"
  assert_success
}

@test "cast agents --usage --json: row keys include agent, dispatches, avg_cost_usd, success_rate" {
  _seed_usage_data
  run bash "$CAST_CLI" --json agents --usage
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = d['rows'][0]
for key in ('agent', 'dispatches', 'avg_cost_usd', 'success_rate'):
    assert key in row, f'missing key: {key}'
"
  assert_success
}

@test "cast agents --usage --json: rows sorted by dispatches descending" {
  _seed_usage_data
  run bash "$CAST_CLI" --json agents --usage
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d['rows']
assert rows[0]['agent'] == 'code-writer', f'expected code-writer first, got {rows[0][\"agent\"]}'
assert rows[0]['dispatches'] == 3
assert rows[1]['agent'] == 'code-reviewer'
assert rows[2]['agent'] == 'debugger'
"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION C: Honesty — zero rows
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage: prints honest message when agent_runs is empty" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  run bash "$CAST_CLI" agents --usage
  assert_success
  assert_output --partial "No agent runs recorded yet"
}

@test "cast agents --usage --json: empty-rows returns valid JSON with empty rows list" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  run bash "$CAST_CLI" --json agents --usage
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['view'] == 'by_agent_usage'
assert d['rows'] == []
"
  assert_success
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION D: DB absent
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents --usage: exits 1 with error when cast.db is absent" {
  # DB was never created — cast.db does not exist
  run bash "$CAST_CLI" agents --usage
  assert_failure
  assert_output --partial "cast.db not found"
}

# ───────────────────────────────────────────────────────────────────────────
# SECTION E: No-flag listing unchanged (regression guard)
# ───────────────────────────────────────────────────────────────────────────

@test "cast agents (no flag): still lists agents without a DB" {
  # Agents dir must exist; DB must NOT be required
  mkdir -p "$HOME/.claude/agents"
  cat > "$HOME/.claude/agents/test-agent.md" <<'MD'
---
name: test-agent
description: A test agent
model: claude-haiku-4-5
---
MD
  export CAST_AGENTS_DIR="$HOME/.claude/agents"
  run bash "$CAST_CLI" agents
  assert_success
  assert_output --partial "test-agent"
  assert_output --partial "agents installed"
}

@test "cast agents (no flag): does not require cast.db to be present" {
  mkdir -p "$HOME/.claude/agents"
  export CAST_AGENTS_DIR="$HOME/.claude/agents"
  # No DB initialized — no agents dir with agents — but must NOT error on missing DB
  run bash "$CAST_CLI" agents
  assert_success
  assert_output --partial "0 agents installed"
}
