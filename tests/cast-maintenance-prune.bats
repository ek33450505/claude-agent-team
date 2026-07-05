#!/usr/bin/env bats
# tests/cast-maintenance-prune.bats — Prune-scope assertions for cast-maintenance.sh
#
# Verifies three prune operations:
#   §2  cast/events/  — files older than 30 days deleted; fresh files survive
#   §3  agent-status/ — files older than 24 h deleted; fresh files survive
#   §4  git worktree prune — scoped to a throwaway temp repo, not the real project
#
# File age is backdated via python3 os.utime (portable; avoids BSD-only date -v).
# Uses isolated temp HOME; never touches real ~/.claude or the live cast.db.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-maintenance.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Backdate a file's atime+mtime by N seconds relative to now.
_backdate() {
  local path="$1"
  local age_secs="$2"
  python3 - "$path" "$age_secs" <<'PY'
import sys, os, time
path, age = sys.argv[1], int(sys.argv[2])
t = time.time() - age
os.utime(path, (t, t))
PY
}

_31_days=$((31 * 86400))
_25_hours=$((25 * 3600))
_1_hour=3600

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Required directory layout mirroring the live ~/.claude structure
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/agent-status"

  export CAST_DB_PATH="$HOME/.claude/cast.db"

  # Provision schema so maintenance does not error on the agent_runs UPDATE
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$CAST_DB_PATH" 2>/dev/null || true

  # Shim GUI/notification surfaces to avoid real side effects
  export PATH="$HOME/bin:$PATH"
  mkdir -p "$HOME/bin"
  for cmd in osascript terminal-notifier notify-send open; do
    printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/$cmd"
    chmod +x "$HOME/bin/$cmd"
  done

  # Create a throwaway git repo at the path the maintenance script scans for
  # worktree prune (~/Projects/personal/claude-agent-team).  Under temp HOME,
  # ~ expands to HOME, so this is fully isolated from the real project repo.
  mkdir -p "$HOME/Projects/personal/claude-agent-team"
  git -C "$HOME/Projects/personal/claude-agent-team" init -q 2>/dev/null || true
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# §2 — cast/events/ prune (>30 days)
# ---------------------------------------------------------------------------

@test "maintenance: events file older than 30 days is pruned" {
  local aged_file="$HOME/.claude/cast/events/old-event.json"
  echo '{"event":"test"}' > "$aged_file"
  _backdate "$aged_file" $_31_days

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ ! -f "$aged_file" ] || {
    echo "FAIL: aged event file was not deleted by maintenance"
    return 1
  }
}

@test "maintenance: events file younger than 30 days survives" {
  local fresh_file="$HOME/.claude/cast/events/fresh-event.json"
  echo '{"event":"fresh"}' > "$fresh_file"
  # mtime is 'now' — do not backdate

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ -f "$fresh_file" ] || {
    echo "FAIL: fresh event file was incorrectly deleted by maintenance"
    return 1
  }
}

@test "maintenance: jsonl.gz events file older than 30 days is pruned" {
  local aged_gz="$HOME/.claude/cast/events/old-archive.jsonl.gz"
  printf '\x1f\x8b' > "$aged_gz"   # minimal gz magic bytes; content irrelevant
  _backdate "$aged_gz" $_31_days

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ ! -f "$aged_gz" ] || {
    echo "FAIL: aged .jsonl.gz event file was not deleted by maintenance"
    return 1
  }
}

# ---------------------------------------------------------------------------
# §3 — agent-status/ prune (>24 h, -mtime +0)
# ---------------------------------------------------------------------------

@test "maintenance: agent-status file older than 24 h is pruned" {
  local aged_status="$HOME/.claude/agent-status/old-agent.json"
  echo '{"status":"done"}' > "$aged_status"
  _backdate "$aged_status" $_25_hours

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ ! -f "$aged_status" ] || {
    echo "FAIL: aged agent-status file was not deleted by maintenance"
    return 1
  }
}

@test "maintenance: agent-status file 1 h old (well within 24 h -mtime +0 threshold) survives" {
  local fresh_status="$HOME/.claude/agent-status/active-agent.json"
  echo '{"status":"running"}' > "$fresh_status"
  _backdate "$fresh_status" $_1_hour

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ -f "$fresh_status" ] || {
    echo "FAIL: recent agent-status file was incorrectly deleted by maintenance"
    return 1
  }
}

# ---------------------------------------------------------------------------
# §4 — git worktree prune (scoped to throwaway temp repo)
# ---------------------------------------------------------------------------

@test "maintenance: git worktree prune runs against temp repo without error" {
  # The throwaway repo at $HOME/Projects/personal/claude-agent-team was created
  # in setup().  maintenance.sh checks 'if [ -d "$repo/.git" ]' before calling
  # git, so the prune executes only against this temp repo — never the real one.
  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success
  # Maintenance logs "Pruned stale worktrees" after the git prune loop
  run grep -q "Pruned stale worktrees" "$HOME/.claude/logs/maintenance.log"
  assert_success
}
