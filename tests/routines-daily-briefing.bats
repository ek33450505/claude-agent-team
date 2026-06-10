#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATION_FILE="$REPO_DIR/scripts/migrations/018_routines.sql"
RUNNER="$REPO_DIR/scripts/cast-routine-runner.sh"
DAILY_BRIEFING_YAML="$REPO_DIR/routines/daily-briefing.yaml"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/routines-output"

  export TEST_DB="$BATS_TEST_TMPDIR/test-daily-briefing-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Apply schema so routines table exists
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_MANAGED_AGENT_CMD
}

# ---------------------------------------------------------------------------
# Wave 3 tests: daily-briefing end-to-end
# ---------------------------------------------------------------------------

@test "daily-briefing.yaml is well-formed and readable" {
  # Verify that the YAML can be parsed without errors via --dry-run
  run env CAST_ROUTINES_DIR="$REPO_DIR/routines" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    bash "$RUNNER" daily-briefing --dry-run

  assert_success
  # Dry run should print the routine plan with agent and output path
  assert_output --partial "agent:       morning-briefing"
  assert_output --partial "output_path:"
}

@test "daily-briefing runner --dry-run prints expected plan structure" {
  run env CAST_ROUTINES_DIR="$REPO_DIR/routines" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    bash "$RUNNER" daily-briefing --dry-run

  assert_success
  assert_output --partial "=== cast-routine-runner dry-run ==="
  assert_output --partial "agent:       morning-briefing"
  assert_output --partial "output_path:"
  assert_output --partial "--- rendered prompt ---"
}

@test "daily-briefing runner with mocked agent writes output to expected path" {
  # Create a mock dispatch script that simulates a successful agent run
  local mock_agent
  mock_agent="$(mktemp -d)/mock-agent.sh"
  cat > "$mock_agent" <<'MOCK'
#!/usr/bin/env bash
# Mock cast-managed-agent.sh: prints fixture output, exits 0.
echo "Mock briefing for agent: $1"
echo "Prompt length: ${#2}"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit 0
MOCK
  chmod +x "$mock_agent"

  # Run the routine with the mock dispatch command
  run env CAST_ROUTINES_DIR="$REPO_DIR/routines" \
    CAST_DB_PATH="$TEST_DB" \
    CAST_MANAGED_AGENT_CMD="$mock_agent" \
    CLAUDE_SUBPROCESS="" \
    bash "$RUNNER" daily-briefing

  assert_success

  # Verify output file was created
  local output_dir="$HOME/.claude/routines-output/daily-briefing"
  [[ -d "$output_dir" ]] || { echo "Output dir does not exist: $output_dir"; exit 1; }

  local output_file
  output_file=$(ls "$output_dir"/*.md 2>/dev/null | head -1)
  [[ -f "$output_file" ]] || { echo "No output file found in $output_dir"; exit 1; }

  # Verify content includes both the routine header and mock output
  grep -q "# Routine: daily-briefing" "$output_file" || { echo "Missing routine header"; exit 1; }
  grep -q "Mock briefing for agent: morning-briefing" "$output_file" || { echo "Missing mock output"; exit 1; }

  # Cleanup
  rm -rf "$(dirname "$mock_agent")"
}

@test "daily-briefing runner with mocked agent updates DB record to success" {
  # Pre-populate the DB row so update-status has a row to update.
  # In production this is done by `cast routines install`; here we
  # bypass install (we want to test the runner, not install).
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT INTO routines (id, name, trigger_type, trigger_value, agent_to_dispatch, prompt_template, output_dir, enabled, created_at) VALUES ('test-id', 'daily-briefing', 'cron', '0 7 * * *', 'morning-briefing', 'test', '$HOME/.claude/routines-output/daily-briefing', 1, '$now');"

  # Create a mock dispatch script
  local mock_agent
  mock_agent="$(mktemp -d)/mock-agent.sh"
  cat > "$mock_agent" <<'MOCK'
#!/usr/bin/env bash
echo "Mock briefing for agent: $1"
echo "Prompt length: ${#2}"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit 0
MOCK
  chmod +x "$mock_agent"

  # Run the routine with the mock dispatch command
  run env CAST_ROUTINES_DIR="$REPO_DIR/routines" \
    CAST_DB_PATH="$TEST_DB" \
    CAST_MANAGED_AGENT_CMD="$mock_agent" \
    CLAUDE_SUBPROCESS="" \
    bash "$RUNNER" daily-briefing

  assert_success

  # Query DB to verify the routine row was updated
  local status last_run
  status=$(sqlite3 "$TEST_DB" "SELECT last_run_status FROM routines WHERE name='daily-briefing';" 2>/dev/null)
  last_run=$(sqlite3 "$TEST_DB" "SELECT last_run_at FROM routines WHERE name='daily-briefing';" 2>/dev/null)

  # Verify status is 'success' and last_run_at is non-empty
  [[ "$status" == "success" ]]
  [[ -n "$last_run" ]]

  # Cleanup
  rm -rf "$(dirname "$mock_agent")"
}
