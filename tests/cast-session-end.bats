#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-session-end.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export TMPDIR="$HOME/tmp"
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
  status TEXT,
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
  run bash "$HOOK_SH" <<< ""

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
  run bash "$HOOK_SH" <<< ""

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
  run bash "$HOOK_SH" <<< ""

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
  run bash "$HOOK_SH" <<< ""

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
  run bash "$HOOK_SH" <<< ""

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
  run bash "$HOOK_SH" <<< ""

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
  bash "$HOOK_SH" <<< "" >/dev/null 2>&1 || true

  # Check that hook-errors.log was written
  [[ -f "$HOME/.claude/logs/hook-errors.log" ]]
  grep -q "Refusing unsafe SESSION_ID" "$HOME/.claude/logs/hook-errors.log" || \
    grep -q "SESSION_ID" "$HOME/.claude/logs/hook-errors.log"
}

# ---------------------------------------------------------------------------
# 9. Hook completes without errors on a clean temp DB
# ---------------------------------------------------------------------------

@test "hook executes successfully on clean database" {
  export CLAUDE_SESSION_ID="test-db-clean"
  run bash "$HOOK_SH" <<< ""

  # Hook must always exit 0 (never blocks)
  assert_success
}

# ---------------------------------------------------------------------------
# Regression: Bug 2 — sessions.ended_at 100% NULL (session_id mismatch)
# (was: hook read CLAUDE_SESSION_ID only; start-hook exports CAST_SESSION_ID)
# ---------------------------------------------------------------------------

@test "session_id from stdin JSON populates sessions.ended_at (Bug 2 fix)" {
  local session_uuid="test-stdin-uuid-${BATS_TEST_NUMBER}"

  # Pre-insert the session row with no ended_at
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at) VALUES ('${session_uuid}', datetime('now'));"

  # Pipe the stdin JSON payload (as the real hook receives it)
  run bash "$HOOK_SH" <<< "{\"session_id\":\"${session_uuid}\"}"
  assert_success

  # ended_at must now be set
  local ended_at
  ended_at="$(sqlite3 "$TEST_DB" "SELECT ended_at FROM sessions WHERE id='${session_uuid}';" 2>/dev/null || echo "")"
  [[ -n "$ended_at" ]]
}

@test "CAST_SESSION_ID env fallback populates sessions.ended_at when no stdin" {
  local session_uuid="test-cast-env-uuid-${BATS_TEST_NUMBER}"

  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at) VALUES ('${session_uuid}', datetime('now'));"

  # No stdin; CAST_SESSION_ID is set (as start-hook exports it)
  export CAST_SESSION_ID="$session_uuid"
  run bash "$HOOK_SH" <<< ""
  assert_success

  local ended_at
  ended_at="$(sqlite3 "$TEST_DB" "SELECT ended_at FROM sessions WHERE id='${session_uuid}';" 2>/dev/null || echo "")"
  [[ -n "$ended_at" ]]
  unset CAST_SESSION_ID
}

@test "stdin JSON session_id takes priority over CAST_SESSION_ID env" {
  local stdin_uuid="test-priority-stdin-${BATS_TEST_NUMBER}"
  local env_uuid="test-priority-env-${BATS_TEST_NUMBER}"

  # Insert both rows; only the stdin one should get ended_at
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at) VALUES ('${stdin_uuid}', datetime('now'));"
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at) VALUES ('${env_uuid}', datetime('now'));"

  export CAST_SESSION_ID="$env_uuid"
  run bash "$HOOK_SH" <<< "{\"session_id\":\"${stdin_uuid}\"}"
  assert_success

  # stdin_uuid row must have ended_at
  local ended_stdin
  ended_stdin="$(sqlite3 "$TEST_DB" "SELECT ended_at FROM sessions WHERE id='${stdin_uuid}';" 2>/dev/null || echo "")"
  [[ -n "$ended_stdin" ]]

  # env_uuid row must NOT have ended_at (stdin took priority)
  local ended_env
  ended_env="$(sqlite3 "$TEST_DB" "SELECT ended_at FROM sessions WHERE id='${env_uuid}';" 2>/dev/null || echo "null")"
  [[ -z "$ended_env" ]] || [[ "$ended_env" == "null" ]]
  unset CAST_SESSION_ID
}

# ---------------------------------------------------------------------------
# Regression: macOS TTY hang — cat blocked when stdin was a terminal
# Root cause: _INPUT="$(cat ...)" blocks when BATS inherits TTY stdin on macOS.
# Fix: (1) hook guards with [[ -t 0 ]]; (2) all tests use '<<< ""' explicitly.
# ---------------------------------------------------------------------------

@test "hook completes within 3s when stdin is an open non-TTY pipe (macOS TTY-hang regression)" {
  # Regression for: cast-session-end.sh hung on macOS native BATS because BATS
  # test processes inherit the terminal (TTY) as stdin — cat in the hook blocks
  # indefinitely. On Ubuntu/Docker CI, stdin is /dev/null so cat returns immediately.
  #
  # Fix: (1) skip cat when stdin is a TTY ([[ -t 0 ]]); (2) skip cat when stdin is
  # an open non-TTY pipe with no data ready (read -t 0 returns false). Tests also get
  # explicit <<< "" to prevent relying on ambient stdin.
  #
  # This test simulates the hang via process substitution (< <(sleep 10)) which keeps
  # the pipe's write end open with no data — identical semantics to an open terminal.
  # Pre-fix: cat blocks → hook never exits → wait loop times out → test FAILS.
  # Post-fix: read -t 0 detects "no data ready" → skips cat → hook exits → PASSES.
  #
  # On bash <4 (macOS system bash 3.2): read -t 0 is unsupported; the hook falls
  # back to plain cat, which blocks on an open pipe with no data. Skip this test
  # when the test runner (and therefore the hook via 'bash $HOOK_SH') is bash <4.
  if (( BASH_VERSINFO[0] < 4 )); then
    skip "read -t 0 unavailable on bash <4; open-pipe guard not active on this runtime"
  fi
  export CLAUDE_SESSION_ID="hang-regress-$$"

  # Hard outer bound: perl alarm(10) kills the entire hook process if it blocks.
  # This converts a potential infinite hang into a bounded FAIL — a hang must
  # never make the whole BATS suite hang (which stalls CI indefinitely).
  # perl is available on macOS and Linux; gtimeout/timeout are not reliably present.
  # The alarm wraps both the hook invocation and the open-pipe stdin source.
  local hook_exit
  perl -e 'alarm 10; exec @ARGV' -- \
    bash -c 'HOME="$HOME" CAST_DB_PATH="$TEST_DB" bash "$HOOK_SH" < <(sleep 10)' &
  local hook_pid=$!

  # Give hook up to 3 seconds to complete (6 × 0.5s polls)
  local i=0
  while [[ $i -lt 6 ]] && kill -0 "$hook_pid" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
  done

  if kill -0 "$hook_pid" 2>/dev/null; then
    # Hook did not complete within 3s — kill it and report an honest FAIL.
    # The perl alarm(10) also terminates the process if kill misses something.
    kill "$hook_pid" 2>/dev/null || true
    wait "$hook_pid" 2>/dev/null || true
    fail "Hook hung reading stdin (macOS TTY-hang regression — cat blocked on open pipe)"
  fi

  wait "$hook_pid" 2>/dev/null || true
}

@test "old CLAUDE_SESSION_ID-only resolution fails to update row (demonstrates pre-fix behavior)" {
  # This test documents that CLAUDE_SESSION_ID alone does NOT match the
  # session_id written by the start-hook (which uses stdin JSON + CAST_SESSION_ID).
  # With the fix in place this test confirms the OLD path is NOT the primary path.
  local real_uuid="real-session-${BATS_TEST_NUMBER}"
  sqlite3 "$TEST_DB" \
    "INSERT INTO sessions (id, started_at) VALUES ('${real_uuid}', datetime('now'));"

  # Set CLAUDE_SESSION_ID to a DIFFERENT value (simulates the pre-fix mismatch)
  export CLAUDE_SESSION_ID="wrong-session-id-${BATS_TEST_NUMBER}"
  # No stdin and no CAST_SESSION_ID — so only CLAUDE_SESSION_ID is available
  unset CAST_SESSION_ID
  run bash "$HOOK_SH" <<< ""
  assert_success

  # The real row must NOT have ended_at (CLAUDE_SESSION_ID didn't match)
  local ended_at
  ended_at="$(sqlite3 "$TEST_DB" "SELECT ended_at FROM sessions WHERE id='${real_uuid}';" 2>/dev/null || echo "")"
  [[ -z "$ended_at" ]]
  unset CLAUDE_SESSION_ID
}
