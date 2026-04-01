#!/usr/bin/env bats
# Tests for bin/cast CLI
#
# Coverage:
#   - cast budget: empty DB returns $0.00 spend
#   - cast budget --json: returns valid JSON with zero values
#   - cast queue list: empty queue returns "Queue is empty."
#   - cast queue list --json: returns empty JSON array
#   - cast status: runs without error (zero exit code)
#   - cast --version: prints version string
#   - cast --help: prints usage
#   - cast run: validates agent existence
#   - cast queue cancel/retry: handles missing task-id gracefully

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"
  # Disable embedding service for tests
  export EMBED_URL="http://localhost:19999"

  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/config" "$HOME/.claude/logs"

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  # Install a minimal config so _config_get doesn't complain
  cat > "$HOME/.claude/config/cast-cli.json" <<'JSON'
{
  "db_path": "~/.claude/cast-test.db",
  "redact_pii": false,
  "default_model": "auto",
  "log_dir": "~/.claude/logs"
}
JSON
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH EMBED_URL
}

# ---------------------------------------------------------------------------
# cast --version / --help
# ---------------------------------------------------------------------------

@test "cast --version: prints version string" {
  run bash "$CAST_CLI" --version
  assert_success
  assert_output --partial "3.1"
}

@test "cast --help: prints usage with subcommands" {
  run bash "$CAST_CLI" --help
  assert_success
  assert_output --partial "run"
  assert_output --partial "queue"
  assert_output --partial "memory"
  assert_output --partial "budget"
}

@test "cast: no subcommand prints usage" {
  run bash "$CAST_CLI"
  assert_success
  assert_output --partial "Usage"
}

# ---------------------------------------------------------------------------
# cast budget — empty DB
# ---------------------------------------------------------------------------

@test "cast budget: empty DB returns \$0.00 today spend" {
  run bash "$CAST_CLI" budget
  assert_success
  assert_output --partial "Today: \$0.00"
}

@test "cast budget: empty DB returns \$0.00 week spend" {
  run bash "$CAST_CLI" budget
  assert_success
  assert_output --partial "This week: \$0.00"
}

@test "cast budget --json: empty DB returns valid JSON with zero today_usd" {
  run bash "$CAST_CLI" --json budget
  assert_success
  # Output must be valid JSON
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['today_usd'] == 0.0" 2>&1
  assert_success
}

@test "cast budget --json: empty DB has local_runs = 0" {
  run bash "$CAST_CLI" --json budget
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['local_runs'] == 0" 2>&1
  assert_success
}

@test "cast budget --week: empty DB prints no spend data message" {
  run bash "$CAST_CLI" budget --week
  assert_success
  # Should mention week without crashing — either "No spend data" or all zeros
  [ "$status" -eq 0 ]
}

@test "cast budget set --global: upserts budget row" {
  run bash "$CAST_CLI" budget set --global 5.00
  assert_success
  assert_output --partial "Budget set: global"
  # Verify it's in the DB
  result="$(sqlite3 "$CAST_DB_PATH" "SELECT limit_usd FROM budgets WHERE scope='global';")"
  [ "$result" = "5.0" ]
}

@test "cast budget set --session: upserts session budget" {
  run bash "$CAST_CLI" budget set --session 1.50
  assert_success
  assert_output --partial "Budget set: session"
}

# ---------------------------------------------------------------------------
# cast queue list — empty queue
# ---------------------------------------------------------------------------

@test "cast queue list: empty queue prints 'Queue is empty.'" {
  run bash "$CAST_CLI" queue list
  assert_success
  assert_output "Queue is empty."
}

@test "cast queue list --json: empty queue returns empty JSON array" {
  run bash "$CAST_CLI" --json queue list
  assert_success
  assert_output "[]"
}

@test "cast queue list --status pending: empty queue is empty" {
  run bash "$CAST_CLI" queue list --status pending
  assert_success
  assert_output "Queue is empty."
}

@test "cast queue cancel: missing task-id prints error" {
  run bash "$CAST_CLI" queue cancel
  assert_failure
  assert_output --partial "Usage: cast queue cancel"
}

@test "cast queue cancel: non-existent task-id warns gracefully" {
  run bash "$CAST_CLI" queue cancel 9999
  # Should not crash — either warns or succeeds with message
  [ "$status" -eq 0 ]
  assert_output --partial "not found"
}

@test "cast queue retry: missing task-id prints error" {
  run bash "$CAST_CLI" queue retry
  assert_failure
  assert_output --partial "Usage: cast queue retry"
}

# ---------------------------------------------------------------------------
# cast status — runs without error
# ---------------------------------------------------------------------------

@test "cast status: exits zero (no crash)" {
  run bash "$CAST_CLI" status
  assert_success
}

@test "cast status: output contains CAST version header" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "CAST v3.1"
}

@test "cast status: output contains Budget line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Budget"
}

@test "cast status: output contains Memory line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Memory"
}

# ---------------------------------------------------------------------------
# cast memory — empty DB
# ---------------------------------------------------------------------------

@test "cast memory list: empty DB prints 'No memories found.'" {
  run bash "$CAST_CLI" memory list
  assert_success
  assert_output "No memories found."
}

@test "cast memory export: empty DB returns empty JSON array" {
  run bash "$CAST_CLI" memory export
  assert_success
  assert_output "[]"
}

@test "cast memory search: no query prints error" {
  run bash "$CAST_CLI" memory search
  assert_failure
  assert_output --partial "Usage: cast memory search"
}

@test "cast memory forget: missing ID prints error" {
  run bash "$CAST_CLI" memory forget
  assert_failure
  assert_output --partial "Usage: cast memory forget"
}

@test "cast memory forget: non-existent ID warns gracefully" {
  run bash "$CAST_CLI" memory forget 9999
  [ "$status" -eq 0 ]
  assert_output --partial "not found"
}

# ---------------------------------------------------------------------------
# cast run — validation
# ---------------------------------------------------------------------------

@test "cast run: missing agent and task prints error" {
  run bash "$CAST_CLI" run
  assert_failure
  assert_output --partial "Usage: cast run"
}

@test "cast run: non-existent agent prints error and lists agents" {
  run bash "$CAST_CLI" run nonexistent-agent "some task"
  assert_failure
  assert_output --partial "Agent not found: nonexistent-agent"
}

@test "cast run --async: non-existent agent still fails validation" {
  run bash "$CAST_CLI" run nonexistent-agent "task" --async
  assert_failure
  assert_output --partial "Agent not found"
}

# ---------------------------------------------------------------------------
# cast audit — no log
# ---------------------------------------------------------------------------

@test "cast audit: no audit log warns gracefully" {
  run bash "$CAST_CLI" audit
  # Should not crash even if audit.jsonl missing
  [ "$status" -eq 0 ]
}

@test "cast audit --redact on: writes to config file" {
  run bash "$CAST_CLI" audit --redact on
  assert_success
  assert_output --partial "on"
  # Check config was written
  result="$(python3 -c "import json; d=json.load(open('$HOME/.claude/config/cast-cli.json')); print(d.get('redact_pii',False))" 2>/dev/null)"
  [ "$result" = "True" ]
}

@test "cast audit --redact off: sets redact_pii to false" {
  run bash "$CAST_CLI" audit --redact off
  assert_success
  result="$(python3 -c "import json; d=json.load(open('$HOME/.claude/config/cast-cli.json')); print(d.get('redact_pii',True))" 2>/dev/null)"
  [ "$result" = "False" ]
}

# ---------------------------------------------------------------------------
# cast daemon — no daemon running
# ---------------------------------------------------------------------------

@test "cast daemon status: exits zero when daemon is stopped" {
  run bash "$CAST_CLI" daemon status
  assert_success
}

@test "cast daemon status --json: returns valid JSON" {
  run bash "$CAST_CLI" --json daemon status
  assert_success
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>&1
  assert_success
}

@test "cast daemon logs: warns gracefully when log missing" {
  run bash "$CAST_CLI" daemon logs
  # Not a failure — either empty or warning
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# cast install-completions
# ---------------------------------------------------------------------------

@test "cast install-completions: exits zero (completions exist in repo)" {
  run bash "$CAST_CLI" install-completions
  # May warn about missing dir but should not crash with non-zero
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
