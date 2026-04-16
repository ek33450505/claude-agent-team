#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-session-end.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export TMPDIR="$HOME/tmp"
  mkdir -p "$HOME/.claude/cast/hook-last-fired"
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$TMPDIR"

  # Create a temp DB with minimal sessions table for testing
  export TEST_DB="$TMPDIR/test.db"
  export CAST_DB_PATH="$TEST_DB"

  # Initialize a minimal sessions table
  sqlite3 "$TEST_DB" <<EOF
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  project TEXT,
  total_input_tokens INTEGER DEFAULT 0,
  total_output_tokens INTEGER DEFAULT 0,
  total_cost_usd REAL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS agent_runs (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  started_at TEXT,
  status TEXT
);

CREATE TABLE IF NOT EXISTS routing_events (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  timestamp TEXT,
  event_type TEXT
);

CREATE TABLE IF NOT EXISTS dispatch_decisions (
  id TEXT PRIMARY KEY,
  created_at TEXT
);

CREATE TABLE IF NOT EXISTS quality_gates (
  id TEXT PRIMARY KEY,
  created_at TEXT
);

CREATE TABLE IF NOT EXISTS stream_events (
  id TEXT PRIMARY KEY,
  timestamp TEXT
);

CREATE TABLE IF NOT EXISTS stream_hook_events (
  id TEXT PRIMARY KEY,
  timestamp TEXT
);

CREATE TABLE IF NOT EXISTS worktree_events (
  id TEXT PRIMARY KEY,
  timestamp TEXT
);

CREATE TABLE IF NOT EXISTS cast_events (
  id TEXT PRIMARY KEY,
  timestamp TEXT
);
EOF

  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH
  unset TEST_DB
}

# ---------------------------------------------------------------------------
# 1. SESSION_ID guard: malformed SESSION_ID (SQL injection chars)
# ---------------------------------------------------------------------------

@test "SESSION_ID with SQL injection chars → guard fires, exit 0, no DB update" {
  # Insert a test row into sessions
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at, ended_at) VALUES ('test-safe', datetime('now'), NULL);"

  # Run the hook with a malicious SESSION_ID
  export CLAUDE_SESSION_ID="'; DROP TABLE sessions; --"
  run bash "$HOOK_SH"

  # Must exit 0 (never block)
  assert_success

  # Verify the sessions table still exists and was NOT updated
  local table_exists
  table_exists=$(sqlite3 "$TEST_DB" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions';" 2>/dev/null || echo "")
  [[ -n "$table_exists" ]]

  # Verify the row was not updated
  local ended_at
  ended_at=$(sqlite3 "$TEST_DB" \
    "SELECT ended_at FROM sessions WHERE id='test-safe';" 2>/dev/null || echo "null")
  [[ "$ended_at" = "null" ]] || [[ -z "$ended_at" ]]
}

# ---------------------------------------------------------------------------
# 2. SESSION_ID with special chars (shell metacharacters)
# ---------------------------------------------------------------------------

@test "SESSION_ID with pipe/semicolon → guard fires, no SQL execution" {
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at, ended_at) VALUES ('test-safe-2', datetime('now'), NULL);"

  export CLAUDE_SESSION_ID="test|whoami; echo hacked"
  run bash "$HOOK_SH"

  assert_success

  # Row should not be updated
  local ended_at
  ended_at=$(sqlite3 "$TEST_DB" \
    "SELECT ended_at FROM sessions WHERE id='test-safe-2';" 2>/dev/null || echo "null")
  [[ "$ended_at" = "null" ]] || [[ -z "$ended_at" ]]
}

# ---------------------------------------------------------------------------
# 3. Normal SESSION_ID: safe alphanumeric + underscore/hyphen passes guard
# ---------------------------------------------------------------------------

@test "safe SESSION_ID (sess-abc123) → passes guard (no rejection)" {
  export CLAUDE_SESSION_ID="sess-abc123"
  run bash "$HOOK_SH"

  # Hook must exit 0 (never block)
  assert_success

  # Verify that guard didn't log an error for this safe ID
  if [[ -f "$HOME/.claude/logs/hook-errors.log" ]]; then
    ! grep -q "Refusing unsafe SESSION_ID.*sess-abc123" "$HOME/.claude/logs/hook-errors.log"
  fi
}

# ---------------------------------------------------------------------------
# 4. SESSION_ID with uppercase/lowercase/numbers/underscores/hyphens passes guard
# ---------------------------------------------------------------------------

@test "SESSION_ID with mixed valid chars (Sess_Test-123) → passes guard" {
  export CLAUDE_SESSION_ID="Sess_Test-123"
  run bash "$HOOK_SH"

  assert_success

  # Verify no error was logged for this safe ID
  if [[ -f "$HOME/.claude/logs/hook-errors.log" ]]; then
    ! grep -q "Refusing unsafe SESSION_ID.*Sess_Test-123" "$HOME/.claude/logs/hook-errors.log"
  fi
}

# ---------------------------------------------------------------------------
# 5. Subprocess guard: CLAUDE_SUBPROCESS=1 exits 0 immediately
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 → exits 0, no hook execution" {
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at, ended_at) VALUES ('sub-test', datetime('now'), NULL);"

  export CLAUDE_SUBPROCESS=1
  export CLAUDE_SESSION_ID="sub-test"
  run bash "$HOOK_SH"

  assert_success

  # Row should NOT be updated (subprocess guard exits early)
  local ended_at
  ended_at=$(sqlite3 "$TEST_DB" \
    "SELECT ended_at FROM sessions WHERE id='sub-test';" 2>/dev/null || echo "null")
  [[ "$ended_at" = "null" ]] || [[ -z "$ended_at" ]]
}

# ---------------------------------------------------------------------------
# 6. Default SESSION_ID when CLAUDE_SESSION_ID is unset passes guard
# ---------------------------------------------------------------------------

@test "unset CLAUDE_SESSION_ID → defaults to 'default', passes guard" {
  unset CLAUDE_SESSION_ID
  run bash "$HOOK_SH"

  assert_success

  # Verify no error for the default safe ID
  if [[ -f "$HOME/.claude/logs/hook-errors.log" ]]; then
    ! grep -q "Refusing unsafe SESSION_ID.*default" "$HOME/.claude/logs/hook-errors.log"
  fi
}

# ---------------------------------------------------------------------------
# 7. Guard logic logs to hook-errors.log on injection attempt
# ---------------------------------------------------------------------------

@test "malformed SESSION_ID → _log_error appends to hook-errors.log" {
  export CLAUDE_SESSION_ID="'; DROP --"
  bash "$HOOK_SH" >/dev/null 2>&1 || true

  # Check that hook-errors.log was written
  [[ -f "$HOME/.claude/logs/hook-errors.log" ]]
  grep -q "Refusing unsafe SESSION_ID" "$HOME/.claude/logs/hook-errors.log" || \
    grep -q "SESSION_ID" "$HOME/.claude/logs/hook-errors.log"
}

# ---------------------------------------------------------------------------
# 8. Hook health marker is always created (independent of guards)
# ---------------------------------------------------------------------------

@test "hook creates timestamp marker regardless of SESSION_ID" {
  export CLAUDE_SESSION_ID="test-marker"
  bash "$HOOK_SH" >/dev/null 2>&1

  [[ -f "$HOME/.claude/cast/hook-last-fired/Stop.timestamp" ]]
  [[ -f "$HOME/.claude/cast/hook-last-fired/SessionEnd.timestamp" ]]
}

# ---------------------------------------------------------------------------
# 9. Hook completes without errors on a clean temp DB
# ---------------------------------------------------------------------------

@test "hook executes successfully on clean database" {
  export CLAUDE_SESSION_ID="test-db-clean"
  run bash "$HOOK_SH"

  # Hook must always exit 0 (never blocks)
  assert_success
}
