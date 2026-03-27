#!/usr/bin/env bats
# Tests for scripts/castd.sh — task execution logic
#
# Coverage:
#   - CLAUDE_BIN points to nonexistent path     → task permanently failed (exit_code=127)
#   - CLAUDE_BIN points to non-executable file  → task permanently failed (exit_code=127)
#   - Stub exits 0 + echoes 'Status: DONE'      → task marked done
#   - Stub exits 0 + echoes 'Status: BLOCKED'   → task marked failed
#   - Stub exits 1 (no status line)             → task marked failed

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CASTD_SH="$REPO_DIR/scripts/castd.sh"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME
  HOME="$(mktemp -d)"

  export CAST_DB_PATH="$HOME/.claude/cast.db"

  mkdir -p "$HOME/.claude/logs" "$HOME/.claude/run" "$HOME/.claude/agents"

  # Initialise the full DB schema into the temp home
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1

  # Wipe any leftover task rows (defensive guard for dirty state from prior runs)
  sqlite3 "$CAST_DB_PATH" \
    "DELETE FROM task_queue;" 2>/dev/null || true

  # Create a fake bin dir prepended to PATH so we can stub system tools
  export FAKE_BIN
  FAKE_BIN="$(mktemp -d)"

  # Fake curl — always reports online so connectivity check never defers tasks
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$FAKE_BIN/curl"

  # Fake osascript — swallow macOS notification calls silently
  cat > "$FAKE_BIN/osascript" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$FAKE_BIN/osascript"

  # mktemp wrapper — castd.sh hardcodes /tmp/castd-fetch.XXXXXX.py which is
  # blocked in the npx-bats sandbox. Redirect any /tmp/ template to TMPDIR.
  export TMPDIR="$HOME/tmp"
  mkdir -p "$TMPDIR"

  cat > "$FAKE_BIN/mktemp" <<'EOF'
#!/bin/bash
TMPDIR="${TMPDIR:-/tmp}"
mkdir -p "$TMPDIR"
args=()
for arg in "$@"; do
  if [[ "$arg" == /tmp/* ]]; then
    args+=("${TMPDIR}/${arg#/tmp/}")
  else
    args+=("$arg")
  fi
done
exec /usr/bin/mktemp "${args[@]}"
EOF
  chmod +x "$FAKE_BIN/mktemp"

  export PATH="$FAKE_BIN:$PATH"

  # Prevent recursive daemon guard from killing child processes we start
  unset CLAUDE_SUBPROCESS
}

teardown() {
  # Clean FAKE_BIN first (outside HOME, may hold running stubs)
  rm -rf "$FAKE_BIN"
  # HOME contains TMPDIR ($HOME/tmp) — remove last so any in-flight writes finish
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH FAKE_BIN CLAUDE_BIN TMPDIR
}

# ---------------------------------------------------------------------------
# Helper: insert a pending task with max_retries=0 (no retry on failure).
# Prints the rowid of the inserted row so tests can query it by ID.
# Using a specific ID avoids confusion with rows seeded by seed_scheduled_tasks,
# which runs inside castd.sh during startup and adds rows with higher IDs.
# ---------------------------------------------------------------------------

insert_task() {
  local agent="${1:-test-agent}"
  local task_text="${2:-run a test task}"
  # Double single-quotes for SQL escaping (sqlite3 CLI does not support
  # prepared-statement ?-binding via command-line arguments).
  local agent_sql="${agent//\'/\'\'}"
  local task_sql="${task_text//\'/\'\'}"
  sqlite3 "$CAST_DB_PATH" "
    INSERT INTO task_queue
      (created_at, project, project_root, agent, task, priority,
       status, retry_count, max_retries, scheduled_for)
    VALUES
      (datetime('now'), 'test-project', NULL, '${agent_sql}', '${task_sql}', 1,
       'pending', 0, 0, NULL);
    SELECT last_insert_rowid();
  "
}

# ---------------------------------------------------------------------------
# Helper: return the status column for a specific task row ID
# ---------------------------------------------------------------------------

task_status_by_id() {
  local task_id="$1"
  sqlite3 "$CAST_DB_PATH" \
    "SELECT status FROM task_queue WHERE id = ${task_id};"
}

# ---------------------------------------------------------------------------
# 1. Nonexistent CLAUDE_BIN path → task permanently failed
# ---------------------------------------------------------------------------

@test "nonexistent CLAUDE_BIN: task is marked failed" {
  local task_id
  task_id=$(insert_task "test-agent" "do something")

  CLAUDE_BIN="/nonexistent/path/to/claude" \
    run bash "$CASTD_SH" --once

  # castd exits 0 even on task failure — the task status in DB is what matters
  [ "$status" -eq 0 ]

  local db_status
  db_status=$(task_status_by_id "$task_id")
  [ "$db_status" = "failed" ]
}

# ---------------------------------------------------------------------------
# 2. Non-executable CLAUDE_BIN file → same 127 path
# ---------------------------------------------------------------------------

@test "non-executable CLAUDE_BIN: task is marked failed" {
  # Create a plain file without the execute bit
  local fake_claude="$HOME/not-executable-claude"
  printf '#!/bin/bash\necho hello\n' > "$fake_claude"
  # intentionally skip: chmod +x

  local task_id
  task_id=$(insert_task "test-agent" "do something")

  CLAUDE_BIN="$fake_claude" \
    run bash "$CASTD_SH" --once

  [ "$status" -eq 0 ]

  local db_status
  db_status=$(task_status_by_id "$task_id")
  [ "$db_status" = "failed" ]
}

# ---------------------------------------------------------------------------
# 3. Stub exits 0 + echoes 'Status: DONE' → task marked done
# ---------------------------------------------------------------------------

@test "stub Status: DONE exit 0: task is marked done" {
  local stub="$FAKE_BIN/claude-done-stub"
  cat > "$stub" <<'EOF'
#!/bin/bash
echo "Status: DONE"
exit 0
EOF
  chmod +x "$stub"

  local task_id
  task_id=$(insert_task "test-agent" "do something")

  CLAUDE_BIN="$stub" \
    run bash "$CASTD_SH" --once

  [ "$status" -eq 0 ]

  local db_status
  db_status=$(task_status_by_id "$task_id")
  [ "$db_status" = "done" ]
}

# ---------------------------------------------------------------------------
# 4. Stub exits 0 + echoes 'Status: BLOCKED' → task marked failed
# ---------------------------------------------------------------------------

@test "stub Status: BLOCKED exit 0: task is marked failed" {
  local stub="$FAKE_BIN/claude-blocked-stub"
  cat > "$stub" <<'EOF'
#!/bin/bash
echo "Status: BLOCKED"
exit 0
EOF
  chmod +x "$stub"

  local task_id
  task_id=$(insert_task "test-agent" "do something")

  CLAUDE_BIN="$stub" \
    run bash "$CASTD_SH" --once

  [ "$status" -eq 0 ]

  local db_status
  db_status=$(task_status_by_id "$task_id")
  [ "$db_status" = "failed" ]
}

# ---------------------------------------------------------------------------
# 5. Stub exits 1 (nonzero, no status line) → task marked failed
# ---------------------------------------------------------------------------

@test "stub exits 1: task is marked failed" {
  local stub="$FAKE_BIN/claude-error-stub"
  cat > "$stub" <<'EOF'
#!/bin/bash
echo "Unexpected error from agent"
exit 1
EOF
  chmod +x "$stub"

  local task_id
  task_id=$(insert_task "test-agent" "do something")

  CLAUDE_BIN="$stub" \
    run bash "$CASTD_SH" --once

  [ "$status" -eq 0 ]

  local db_status
  db_status=$(task_status_by_id "$task_id")
  [ "$db_status" = "failed" ]
}

# ---------------------------------------------------------------------------
# 6. Empty queue → castd --once exits cleanly without touching the DB
# ---------------------------------------------------------------------------

@test "empty queue: castd --once exits zero without error" {
  # No tasks inserted — queue is empty
  CLAUDE_BIN="/nonexistent/claude" \
    run bash "$CASTD_SH" --once

  assert_success
}
