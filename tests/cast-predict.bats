#!/usr/bin/env bats
# Tests for `cast predict` — v9 F2 record→decision reader

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# Seed fixture data: one session whose routing_events match "widget crash",
# one debugger agent_run, and one incident mentioning "widget crash".
_seed_fixtures() {
  local db="$CAST_DB_PATH"
  sqlite3 "$db" <<'SQL'
-- Session that represents a "widget crash" task
INSERT INTO sessions (id, project, started_at, status)
VALUES ('sess-widget-001', 'test-project', '2026-06-01T10:00:00Z', 'ended');

-- Routing events with prompt_preview containing the fixture keywords
INSERT INTO routing_events (session_id, timestamp, prompt_preview, event_type)
VALUES
  ('sess-widget-001', '2026-06-01T10:00:01Z', 'fix the widget crash on load', 'UserPromptSubmit'),
  ('sess-widget-001', '2026-06-01T10:00:02Z', 'the widget is crashing at startup', 'UserPromptSubmit');

-- Agent run for that session
INSERT INTO agent_runs (session_id, agent, started_at, status, cost_usd)
VALUES ('sess-widget-001', 'debugger', '2026-06-01T10:00:05Z', 'DONE', 0.42);

-- Incident that relates to widget crash
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary, related_commit, resolution_status)
VALUES (
  'inc-widget-001',
  '2026-06-01T09:00:00Z',
  'widget crash caused by null pointer on load',
  'added null check in widget loader',
  'abcdef1234567890',
  'resolved'
);
SQL
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CAST_AGENTS_DIR="$REPO_DIR/agents/core"
  export CAST_JOURNAL_DIR="$BATS_TEST_TMPDIR/journal"
  export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
  export CLAUDE_SUBPROCESS=0
  mkdir -p "$CAST_JOURNAL_DIR" "$CLAUDE_PROJECTS_DIR"
  # Bootstrap full schema (canonical db-init)
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
}

teardown() {
  teardown_temp_home
}

# ── Test 1: keyword match → cost line + debugger suggestion + incident ────────

@test "cast predict: matching task shows cost prediction, suggests debugger, surfaces incident" {
  _seed_fixtures

  run bash "$CAST_BIN" predict "widget crash"

  assert_success
  # Section 1: cost line present (median / mean / range)
  assert_output --partial "Tasks like this:"
  assert_output --partial "median"
  # Section 2: debugger suggested
  assert_output --partial "debugger"
  assert_output --partial "DONE"
  # Section 3: incident surfaced
  assert_output --partial "widget crash caused by null pointer"
  assert_output --partial "added null check"
}

# ── Test 2: no matching keywords → honest "No similar tasks found" message ────

@test "cast predict: unrelated query prints honest no-match message without fabricating" {
  _seed_fixtures

  run bash "$CAST_BIN" predict "totally unrelated quantum xylophone"

  assert_success
  assert_output --partial "No similar tasks found"
  # Must NOT invent cost or agent data
  refute_output --partial "Tasks like this:"
  refute_output --partial "median"
}

# ── Test 3: --json outputs valid JSON with the three sections ─────────────────

@test "cast predict: --json outputs valid parseable JSON with cost/agents/incidents keys" {
  _seed_fixtures

  run bash "$CAST_BIN" predict "widget crash" --json

  assert_success
  # Must be valid JSON
  echo "$output" | python3 -m json.tool >/dev/null
  # Must contain the three top-level keys
  assert_output --partial '"cost_prediction"'
  assert_output --partial '"suggested_agents"'
  assert_output --partial '"related_incidents"'
  # Cost data populated
  assert_output --partial '"median_usd"'
  # Matched sessions > 0
  assert_output --partial '"matched_sessions"'
}
