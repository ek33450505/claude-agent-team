#!/usr/bin/env bats
# tests/cast-maintenance-timestamps.bats — C7 regression: cast-maintenance.sh
# must write ISO-8601 UTC timestamps (YYYY-MM-DDTHH:MM:SSZ) to agent_runs.ended_at,
# not SQLite's space-format datetime('now') which produces 'YYYY-MM-DD HH:MM:SS'.
#
# Uses isolated temp HOME; never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-maintenance.sh"

# Stub osascript / terminal-notifier / notify-send / open to avoid GUI side effects.
setup() {
  load 'helpers/setup'
  setup_temp_home

  # Create required dirs so maintenance doesn't error on missing dirs
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/agent-status"

  export TEST_DB="$HOME/.claude/cast.db"
  export CAST_DB_PATH="$TEST_DB"

  # Provision schema
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true

  # Insert a stale running agent_run (started >3 hours ago) so maintenance will flip it
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

@test "maintenance flips stale running row to failed" {
  # Execute with CAST_SCRIPTS_DIR pointing at repo scripts so source guards resolve
  CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null

  status=$(sqlite3 "$TEST_DB" "SELECT status FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")
  [ "$status" = "failed" ]
}

@test "maintenance writes ISO-8601 ended_at (T separator, Z suffix) — C7 regression" {
  # Regression: formerly wrote datetime('now') → 'YYYY-MM-DD HH:MM:SS' (no T, no Z)
  CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null

  ended_at=$(sqlite3 "$TEST_DB" "SELECT ended_at FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")

  # Must contain 'T' separator and end with 'Z'
  [[ "$ended_at" == *T*Z ]]
}

@test "maintenance ended_at does not contain space-format timestamp" {
  CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null

  ended_at=$(sqlite3 "$TEST_DB" "SELECT ended_at FROM agent_runs WHERE agent='stale-bot' LIMIT 1;")

  # Space-format would look like '2026-06-13 07:48:22' — no 'T'
  [[ "$ended_at" != *" "* ]]
}
