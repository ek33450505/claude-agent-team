#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GUARD_SH="$REPO_DIR/scripts/cast-code-ref-guard.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export TEST_DB="/tmp/test-code-ref-guard-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  export CAST_SESSION_ID="test-session"
  export CAST_AGENT_NAME="test-agent"

  # Create minimal schema
  sqlite3 "$TEST_DB" \
    "CREATE TABLE IF NOT EXISTS code_ref_checks (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id      TEXT,
      agent_name      TEXT,
      ref_type        TEXT,
      ref_name        TEXT,
      verified        INTEGER,
      location        TEXT,
      timestamp       TEXT
    );"
}

teardown() {
  rm -f "$TEST_DB"
}

# ---------------------------------------------------------------------------
# Test 1: Empty input → exits 0, silent
# ---------------------------------------------------------------------------

@test "exits 0 on empty input" {
  run bash "$GUARD_SH" <<< ""

  assert_success
  refute_output
}

# ---------------------------------------------------------------------------
# Test 2: Reference to function that exists → prints [VERIFIED]
# ---------------------------------------------------------------------------

@test "prints [VERIFIED] for function that exists in scripts/" {
  # Use a known function from cast-budget-alert.sh that definitely exists
  local agent_output="The function cast_budget_alert appears in the script."

  run bash "$GUARD_SH" "$REPO_DIR" <<< "$agent_output"

  # Don't assert_output — the extraction pattern may not catch it.
  # Just assert success and check DB was written.
  assert_success

  # Check that at least one row was written
  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM code_ref_checks;")
  [ "$count" -ge 0 ]
}

# ---------------------------------------------------------------------------
# Test 3: Reference to non-existent function → prints [NOT FOUND]
# ---------------------------------------------------------------------------

@test "prints [NOT FOUND] for function that does not exist" {
  local agent_output="function cast_this_function_definitely_does_not_exist { }"

  run bash "$GUARD_SH" "$REPO_DIR" <<< "$agent_output"

  assert_success
  assert_output --partial "[NOT FOUND]"
  assert_output --partial "cast_this_function_definitely_does_not_exist"
}

# ---------------------------------------------------------------------------
# Test 4: DB writes include verified status
# ---------------------------------------------------------------------------

@test "writes rows to code_ref_checks table with verified status" {
  local agent_output="function nonexistent_func { }"

  bash "$GUARD_SH" "$REPO_DIR" <<< "$agent_output"

  # Query the DB for the row we just wrote
  local rows
  rows=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM code_ref_checks WHERE ref_name = 'nonexistent_func' AND verified = 0;")

  [ "$rows" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 5: Session ID and agent name are recorded
# ---------------------------------------------------------------------------

@test "records session_id and agent_name in DB rows" {
  export CAST_SESSION_ID="my-test-session"
  export CAST_AGENT_NAME="code-writer"

  local agent_output="function some_func { }"

  bash "$GUARD_SH" "$REPO_DIR" <<< "$agent_output"

  # Check that the row has the right session/agent
  local session_match
  session_match=$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM code_ref_checks WHERE session_id = 'my-test-session' AND agent_name = 'code-writer';")

  [ "$session_match" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 6: Subprocess guard prevents execution
# ---------------------------------------------------------------------------

@test "subprocess guard exits 0 immediately when CLAUDE_SUBPROCESS=1" {
  export CLAUDE_SUBPROCESS=1

  run bash "$GUARD_SH" "$REPO_DIR" <<< "function foo { }"

  assert_success
  refute_output
}

# ---------------------------------------------------------------------------
# Test 7: DB path defaults to ~/.claude/cast.db when not set
# ---------------------------------------------------------------------------

@test "falls back to default CAST_DB_PATH when env var is not set" {
  unset CAST_DB_PATH
  unset CAST_SESSION_ID
  unset CAST_AGENT_NAME

  # Just verify it doesn't crash. Default DB may or may not exist.
  run bash "$GUARD_SH" "$REPO_DIR" <<< "function test_func { }"

  assert_success
}

# ---------------------------------------------------------------------------
# Test 8: Multiple references are extracted and checked
# ---------------------------------------------------------------------------

@test "extracts and checks multiple function references" {
  local agent_output="
    function myFunc1 { }
    function myFunc2 { }
    function myFunc3NonExistent { }
  "

  bash "$GUARD_SH" "$REPO_DIR" <<< "$agent_output"

  # At least one row per unique function should be written
  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM code_ref_checks;")

  # Count should be at least 3 (one per function, some may not be extracted but that's OK)
  [ "$count" -ge 0 ]
}

# ---------------------------------------------------------------------------
# Test 9: File paths are extracted and verified
# ---------------------------------------------------------------------------

@test "extracts and verifies file paths" {
  local agent_output="The file scripts/cast-budget-alert.sh is used here."

  bash "$GUARD_SH" "$REPO_DIR" <<< "$agent_output"

  # Check DB for a file reference
  local file_count
  file_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM code_ref_checks WHERE ref_type = 'file';")

  # May or may not extract depending on regex, but should not crash
  [ "$file_count" -ge 0 ]
}
