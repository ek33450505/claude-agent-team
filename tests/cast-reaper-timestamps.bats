#!/usr/bin/env bats
# tests/cast-reaper-timestamps.bats — C7/C3 regression, migrated in v10 I-2b:
# scripts/cast-abandon-stale-runs.py is now the SOLE reaper of stale agent_runs
# rows. The reaping UPDATEs formerly in scripts/cast-maintenance.sh and
# scripts/cast-session-end.sh were DELETED (they raced this reaper with no
# coordination, so the same stale row landed as 'abandoned' or 'failed'
# depending only on which fired first). This file:
#   - retargets the C7 (ISO-8601 ended_at, never SQLite space-format) and C3
#     (explicit no-response marker, never clobbered) coverage that used to
#     live in tests/cast-maintenance-timestamps.bats onto the new sole owner
#   - adds consolidation regressions proving the two old reapers stay inert,
#     so the race can never silently come back
#
# Uses isolated temp HOME; never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-abandon-stale-runs.py"
MAINT_SCRIPT="$REPO_DIR/scripts/cast-maintenance.sh"
SESSION_END_SCRIPT="$REPO_DIR/scripts/cast-session-end.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Create required dirs so maintenance/session-end don't error on missing dirs
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/agent-status"

  export TEST_DB="$HOME/.claude/cast.db"
  export CAST_DB_PATH="$TEST_DB"

  # Provision schema
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true

  # Insert a stale running agent_run (started >3 hours ago) so the reaper will flip it
  stale_ts=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sqlite3 "$TEST_DB" "INSERT INTO agent_runs (agent, status, started_at) VALUES ('stale-bot', 'running', '$stale_ts');"

  # Shim tools that could emit desktop notifications or open URLs
  export PATH="$HOME/bin:$PATH"
  mkdir -p "$HOME/bin"
  for cmd in osascript terminal-notifier notify-send open; do
    printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/$cmd"
    chmod +x "$HOME/bin/$cmd"
  done
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Sole-reaper coverage (scripts/cast-abandon-stale-runs.py)
# ---------------------------------------------------------------------------

@test "reaper flips stale running row to abandoned (not failed)" {
  run python3 "$SCRIPT"
  assert_success

  status=$(sqlite3 "$TEST_DB" "SELECT status FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ "$status" = "abandoned" ]
}

@test "reaper sets ended_at (NOT NULL) — v10 I-2b new behavior" {
  run python3 "$SCRIPT"
  assert_success

  ended_at=$(sqlite3 "$TEST_DB" "SELECT ended_at FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ -n "$ended_at" ]
}

@test "reaper writes ISO-8601 ended_at (T separator, Z suffix) — C7 regression" {
  # Regression: formerly (in the old bash reapers) wrote datetime('now') →
  # 'YYYY-MM-DD HH:MM:SS' (no T, no Z)
  run python3 "$SCRIPT"
  assert_success

  ended_at=$(sqlite3 "$TEST_DB" "SELECT ended_at FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")

  # Must contain 'T' separator and end with 'Z'
  [[ "$ended_at" == *T*Z ]]
}

@test "reaper ended_at does not contain space-format timestamp — C7 regression" {
  run python3 "$SCRIPT"
  assert_success

  ended_at=$(sqlite3 "$TEST_DB" "SELECT ended_at FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")

  # Space-format would look like '2026-06-13 07:48:22' — no 'T'
  [[ "$ended_at" != *" "* ]]
}

@test "reaper sets abandoned_at as well" {
  run python3 "$SCRIPT"
  assert_success

  abandoned_at=$(sqlite3 "$TEST_DB" "SELECT abandoned_at FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ -n "$abandoned_at" ]
}

@test "reaper never clobbers an already-populated ended_at — COALESCE guard" {
  sqlite3 "$TEST_DB" "UPDATE agent_runs SET ended_at='2020-01-01T00:00:00Z' WHERE agent='stale-bot';"
  run python3 "$SCRIPT"
  assert_success

  ended_at=$(sqlite3 "$TEST_DB" "SELECT ended_at FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ "$ended_at" = "2020-01-01T00:00:00Z" ]
}

@test "reaper writes an explicit no-response marker, not NULL — C3 fix" {
  # C3 (plans/c2-c3-response-loss-findings.md): SubagentStop never fires for a row
  # that's still 'running' at the reap threshold, so response was always NULL —
  # indistinguishable from a DONE run with a legitimately-empty response.
  run python3 "$SCRIPT"
  assert_success

  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ -n "$response" ]
  [[ "$response" == *"SubagentStop never fired"* ]]
}

@test "reaper never clobbers an already-populated response — C3 fix" {
  sqlite3 "$TEST_DB" "UPDATE agent_runs SET response='real response text' WHERE agent='stale-bot';"
  run python3 "$SCRIPT"
  assert_success

  response=$(sqlite3 "$TEST_DB" "SELECT response FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ "$response" = "real response text" ]
}

# ---------------------------------------------------------------------------
# Consolidation regressions — the removed reapers must stay inert. Both are
# BEHAVIORAL (execute the script, assert DB state), not source greps: a grep
# for the deleted UPDATE text would be exactly true today and say nothing
# about whether either script actually still reaps at runtime.
# ---------------------------------------------------------------------------

@test "cast-maintenance.sh no longer reaps stale agent_runs rows" {
  CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$MAINT_SCRIPT" 2>/dev/null

  status=$(sqlite3 "$TEST_DB" "SELECT status FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ "$status" = "running" ]
}

@test "cast-session-end.sh no longer reaps stale agent_runs rows" {
  export CLAUDE_SESSION_ID="reaper-consolidation-check"
  run bash "$SESSION_END_SCRIPT" <<< ""
  assert_success

  status=$(sqlite3 "$TEST_DB" "SELECT status FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ "$status" = "running" ]
}
