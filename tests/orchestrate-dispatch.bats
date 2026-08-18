#!/usr/bin/env bats
# tests/orchestrate-dispatch.bats — Regression tests for orchestrate-dispatch.py
#
# C3 regression: log-quality-gate must strip the "Status: " prefix that orchestrator
# LLMs commonly include verbatim (e.g. "--status 'Status: DONE'" must write "DONE"
# to quality_gates.status_line, not "Status: DONE").
#
# Tests use an isolated temp DB; never touch real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/orchestrate-dispatch.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  export TEST_DB="$HOME/orchestrate-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  # Provision schema
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# C3 regression: status_line must hold enum only, not "Status: DONE"
# ---------------------------------------------------------------------------

@test "log-quality-gate strips 'Status: DONE' prefix — writes enum 'DONE'" {
  run python3 "$SCRIPT" log-quality-gate \
    --batch-id 1 --agent code-writer \
    --status "Status: DONE" \
    --contract-passed 1 --retry-count 0
  assert_success

  written=$(sqlite3 "$TEST_DB" "SELECT status_line FROM quality_gates ORDER BY rowid DESC LIMIT 1;")
  [ "$written" = "DONE" ]
}

@test "log-quality-gate strips 'Status: BLOCKED' prefix — writes enum 'BLOCKED'" {
  run python3 "$SCRIPT" log-quality-gate \
    --batch-id 1 --agent debugger \
    --status "Status: BLOCKED" \
    --contract-passed 0 --retry-count 1
  assert_success

  written=$(sqlite3 "$TEST_DB" "SELECT status_line FROM quality_gates ORDER BY rowid DESC LIMIT 1;")
  [ "$written" = "BLOCKED" ]
}

@test "log-quality-gate passes through bare enum without modification" {
  run python3 "$SCRIPT" log-quality-gate \
    --batch-id 1 --agent code-reviewer \
    --status "DONE_WITH_CONCERNS" \
    --contract-passed 1 --retry-count 0
  assert_success

  written=$(sqlite3 "$TEST_DB" "SELECT status_line FROM quality_gates ORDER BY rowid DESC LIMIT 1;")
  [ "$written" = "DONE_WITH_CONCERNS" ]
}

@test "log-quality-gate writes UUID-format id, not 8-byte hex" {
  run python3 "$SCRIPT" log-quality-gate \
    --batch-id 1 --agent test-runner \
    --status "DONE" \
    --contract-passed 1 --retry-count 0
  assert_success

  written_id=$(sqlite3 "$TEST_DB" "SELECT id FROM quality_gates ORDER BY rowid DESC LIMIT 1;")
  # UUID format: 8-4-4-4-12 hex with hyphens (36 chars)
  [[ "$written_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# ---------------------------------------------------------------------------
# LF-10: recent-status must find a "<agent>__<label>" dispatch-naming status
# file, not just a bare "<agent>-<ts>.json" one (working-conventions.md
# dispatch-naming rule requires roster dispatches be named <agent>__<label>).
# ---------------------------------------------------------------------------

@test "recent-status finds a code-reviewer__label-<ts>.json status file" {
  status_dir="$HOME/.claude/agent-status"
  mkdir -p "$status_dir"
  echo '{"status":"DONE"}' > "$status_dir/code-reviewer__fix-advisory-1234567890.json"

  run python3 "$SCRIPT" recent-status --agent code-reviewer --max-age 999999999
  assert_success
  assert_output "DONE"
}

@test "recent-status still finds a bare code-reviewer-<ts>.json status file (regression guard)" {
  status_dir="$HOME/.claude/agent-status"
  mkdir -p "$status_dir"
  echo '{"status":"DONE"}' > "$status_dir/code-reviewer-1234567890.json"

  run python3 "$SCRIPT" recent-status --agent code-reviewer --max-age 999999999
  assert_success
  assert_output "DONE"
}

@test "recent-status does not match an unrelated agent name (code-reviewer2)" {
  status_dir="$HOME/.claude/agent-status"
  mkdir -p "$status_dir"
  echo '{"status":"DONE"}' > "$status_dir/code-reviewer2-1234567890.json"

  run python3 "$SCRIPT" recent-status --agent code-reviewer --max-age 999999999
  assert_success
  assert_output ""
}

@test "recent-status picks the newest file across bare and __-named variants" {
  status_dir="$HOME/.claude/agent-status"
  mkdir -p "$status_dir"
  echo '{"status":"DONE"}' > "$status_dir/code-reviewer-1111111111.json"
  # Fixed, unambiguously-old mtime (POSIX -t format: both BSD and GNU touch
  # accept [[CC]YY]MMDDhhmm) so the newer __-named file below sorts last.
  touch -t 202001010000 "$status_dir/code-reviewer-1111111111.json"
  echo '{"status":"BLOCKED"}' > "$status_dir/code-reviewer__fix-advisory-2222222222.json"

  run python3 "$SCRIPT" recent-status --agent code-reviewer --max-age 999999999
  assert_success
  assert_output "BLOCKED"
}
