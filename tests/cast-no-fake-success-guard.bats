#!/usr/bin/env bats
# Regression tests for cast-no-fake-success-guard.sh
# Covers: fake-success detection in Python, JS/TS try/catch patterns

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GUARD="$REPO_DIR/scripts/cast-no-fake-success-guard.sh"

setup() {
  export CLAUDE_SUBPROCESS=0
  export CAST_DB_PATH="/tmp/test-cast-$$-fakesuccess.db"

  # Initialize a minimal test DB (optional, for future logging)
  sqlite3 "$CAST_DB_PATH" <<'SQL' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS quality_gates (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  batch_id INTEGER,
  agent_name TEXT,
  timestamp TEXT,
  status_line TEXT,
  contract_passed INTEGER,
  retry_count INTEGER
);
SQL
}

teardown() {
  rm -f "$CAST_DB_PATH" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Positive cases: should warn on fake-success patterns
# ---------------------------------------------------------------------------

@test "warns on Python file with try/except return sample_data (case variant SAMPLE)" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/handler.py","content":"try:\n  result = fetch()\nexcept:\n  return SAMPLE_DATA"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output --partial "hookSpecificOutput"
  assert_output --partial "FAKE-SUCCESS WARN"
}

@test "warns on Python file with multi-line try/except return fake_response" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/api.py","content":"try:\n  x = call()\nexcept Exception:\n  return fake_response()"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output --partial "FAKE-SUCCESS WARN"
}

@test "warns on JS file with try/catch returning mock array" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/fetch.js","content":"try { return fetch(); } catch (e) { return [{fake: true}]; }"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output --partial "FAKE-SUCCESS WARN"
}

@test "warns on TS file with try/catch returning sample object" {
  PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/service.ts","new_string":"try { const x = await api(); } catch { return {sample: 1}; }"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output --partial "FAKE-SUCCESS WARN"
}

# ---------------------------------------------------------------------------
# Negative cases: should NOT warn (skip conditions or no match)
# ---------------------------------------------------------------------------

@test "skips Python test file at tests/handler.test.py" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/tests/handler.test.py","content":"try:\n  result = fetch()\nexcept:\n  return mock_data"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

@test "skips .test.ts file" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/service.test.ts","content":"try { api(); } catch { return {mock: 1}; }"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

@test "skips .spec.js file" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/spec.spec.js","content":"try { call(); } catch { return fake_result; }"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

@test "skips fixtures/ directory" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/fixtures/sample.json","content":"try catch mock"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

@test "skips non-code language (.go file)" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/handler.go","content":"try catch mock return fake"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

@test "does not match plain return without surrounding try/except" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/func.py","content":"def get_data():\n  return sample_data"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

@test "skips when content contains fake-success-ok comment suppression" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/api.ts","content":"try { call(); } catch { return {fake: 1}; /* fake-success-ok */ }"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Contract and behavior tests
# ---------------------------------------------------------------------------

@test "always exits 0 (warn-only, never blocks)" {
  # Even on a matching pattern, exit code must be 0
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.py","content":"try:\n  x = 1\nexcept:\n  return mock_data"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_equal "$status" 0
}

@test "hookSpecificOutput is a JSON object, not a stringified blob" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.py","content":"try:\n  x = 1\nexcept:\n  return fake_data"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success

  # Verify output is valid JSON
  output_parsed=$(echo "$output" | jq . 2>/dev/null || echo "INVALID_JSON")
  [ "$output_parsed" != "INVALID_JSON" ]

  # Verify hookSpecificOutput is an object, not a string
  hso_type=$(echo "$output" | jq -r '.hookSpecificOutput | type' 2>/dev/null)
  [ "$hso_type" = "object" ]
}

@test "subprocess guard exits 0 when CLAUDE_SUBPROCESS=1" {
  CLAUDE_SUBPROCESS=1 run bash "$GUARD" <<< '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.py","content":"try:\n  x=1\nexcept:\n  return mock"}}'
  assert_success
}

@test "skips when tool_name is not Write or Edit" {
  PAYLOAD='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py","content":"try catch mock fake"}}'
  run bash "$GUARD" <<< "$PAYLOAD"
  assert_success
  assert_output ""
}

@test "handles empty stdin gracefully" {
  run bash "$GUARD" <<< ""
  assert_success
}

@test "logs warn event to cast.db quality_gates" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.py","content":"try:\n  x=1\nexcept:\n  return fake_data"}}'
  CAST_DB_PATH="$CAST_DB_PATH" run bash "$GUARD" <<< "$PAYLOAD"
  assert_success

  # Verify the warn event was logged to the database
  GATE_COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM quality_gates WHERE agent_name='cast-no-fake-success-guard';" 2>/dev/null || echo "0")
  [ "$GATE_COUNT" -eq 1 ]
}

@test "handles file path containing single quote without crashing" {
  PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/Don'"'"'t.py","content":"try:\n  x=1\nexcept:\n  return fake_data"}}'
  CAST_DB_PATH="$CAST_DB_PATH" run bash "$GUARD" <<< "$PAYLOAD"
  assert_success

  # Verify the row with apostrophe was logged successfully
  GATE_COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM quality_gates WHERE agent_name='cast-no-fake-success-guard' AND status_line LIKE '%Don''t%';" 2>/dev/null || echo "0")
  [ "$GATE_COUNT" -eq 1 ]
}
