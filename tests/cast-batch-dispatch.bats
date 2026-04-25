#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BATCH_DISPATCH_SH="$REPO_DIR/scripts/cast-batch-dispatch.sh"
CAST_BATCH_STATUS_SH="$REPO_DIR/scripts/cast-batch-status.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export ORIG_PATH="$PATH"

  export HOME="$(mktemp -d)"
  export BATS_TMPDIR="${HOME}/bats-tmp"
  mkdir -p "$BATS_TMPDIR"

  # Mock curl in PATH
  MOCK_BIN_DIR="${BATS_TMPDIR}/bin"
  mkdir -p "$MOCK_BIN_DIR"
  export PATH="${MOCK_BIN_DIR}:${ORIG_PATH}"

  # Create mock curl that can be configured per test
  cat > "${MOCK_BIN_DIR}/curl" <<'CURL_MOCK'
#!/bin/bash
# Mock curl for testing
if [ -f "${BATS_TMPDIR}/curl-response.json" ]; then
  cat "${BATS_TMPDIR}/curl-response.json"
else
  # Default: successful batch create response
  cat <<EOF
{"id":"msgbatch_test123","type":"message_batch","processing_status":"in_progress","request_counts":{"processing":1,"succeeded":0,"errored":0},"created_at":"2024-01-15T10:30:00Z","expires_at":"2024-01-16T10:30:00Z"}
EOF
fi
CURL_MOCK
  chmod +x "${MOCK_BIN_DIR}/curl"

  # Create prompt test file
  export PROMPT_FILE="${BATS_TMPDIR}/prompt.txt"
  echo "Test prompt content" > "$PROMPT_FILE"

  # Set ANTHROPIC_API_KEY
  export ANTHROPIC_API_KEY="test-api-key-12345"
  export CAST_DB_PATH="${HOME}/.claude/cast.db"
}

teardown() {
  export PATH="$ORIG_PATH"
  export HOME="$ORIG_HOME"
  unset BATS_TMPDIR MOCK_BIN_DIR PROMPT_FILE ANTHROPIC_API_KEY CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# Tests for cast-batch-dispatch.sh
# ---------------------------------------------------------------------------

@test "dispatch: with valid args and ANTHROPIC_API_KEY, returns batch_id" {
  run bash "$CAST_BATCH_DISPATCH_SH" commit "$PROMPT_FILE"
  assert_success
  assert_output "msgbatch_test123"
}

@test "dispatch: missing ANTHROPIC_API_KEY exits 1 with clear error" {
  unset ANTHROPIC_API_KEY
  run bash "$CAST_BATCH_DISPATCH_SH" commit "$PROMPT_FILE"
  assert_failure
  assert_output --partial "ANTHROPIC_API_KEY environment variable not set"
}

@test "dispatch: missing prompt file exits 1" {
  run bash "$CAST_BATCH_DISPATCH_SH" commit "/nonexistent/file.txt"
  assert_failure
  assert_output --partial "prompt file not found"
}

@test "dispatch: missing agent name exits 1" {
  run bash "$CAST_BATCH_DISPATCH_SH"
  assert_failure
}

@test "dispatch: writes to batch_dispatches table in cast.db" {
  run bash "$CAST_BATCH_DISPATCH_SH" commit "$PROMPT_FILE"
  assert_success

  # Verify database row was created
  QUERY="SELECT batch_id, agent, custom_id FROM batch_dispatches WHERE agent='commit'"
  python3 - "$CAST_DB_PATH" "$QUERY" <<'PYEOF'
import sys
import sqlite3
db_path = sys.argv[1]
query = sys.argv[2]
try:
  conn = sqlite3.connect(db_path)
  rows = conn.execute(query).fetchall()
  if rows:
    batch_id, agent, custom_id = rows[0]
    print(f"batch_id={batch_id} agent={agent} custom_id={custom_id}")
  else:
    print("NO_ROWS")
  conn.close()
except Exception as e:
  print(f"ERROR: {e}")
PYEOF
}

@test "dispatch: custom_id format is cast-<agent>-<timestamp>" {
  run bash "$CAST_BATCH_DISPATCH_SH" myagent "$PROMPT_FILE"
  assert_success

  # Verify database row custom_id matches pattern
  python3 - "$CAST_DB_PATH" <<'PYEOF'
import sys
import sqlite3
import re
db_path = sys.argv[1]
try:
  conn = sqlite3.connect(db_path)
  rows = conn.execute("SELECT custom_id FROM batch_dispatches WHERE agent='myagent'").fetchall()
  if rows:
    custom_id = rows[0][0]
    # Should match cast-<agent>-<digits>
    if re.match(r'^cast-myagent-\d+$', custom_id):
      print("OK")
    else:
      print(f"FAIL: {custom_id}")
  conn.close()
except Exception as e:
  print(f"ERROR: {e}")
PYEOF
}

# ---------------------------------------------------------------------------
# Tests for cast-batch-status.sh
# ---------------------------------------------------------------------------

@test "status: with valid batch_id, returns tab-separated counts" {
  # Set up mock response for status call
  cat > "${BATS_TMPDIR}/curl-response.json" <<'RESPONSE'
{"id":"msgbatch_test123","type":"message_batch","processing_status":"in_progress","request_counts":{"processing":1,"succeeded":0,"errored":0,"canceled":0},"created_at":"2024-01-15T10:30:00Z","expires_at":"2024-01-16T10:30:00Z"}
RESPONSE

  run bash "$CAST_BATCH_STATUS_SH" msgbatch_test123
  assert_success
  assert_output --partial "in_progress"
}

@test "status: with ended batch, includes results_url in output" {
  cat > "${BATS_TMPDIR}/curl-response.json" <<'RESPONSE'
{"id":"msgbatch_test456","type":"message_batch","processing_status":"ended","request_counts":{"processing":0,"succeeded":1,"errored":0,"canceled":0},"results_url":"https://storage.googleapis.com/...","created_at":"2024-01-15T10:30:00Z","expires_at":"2024-01-16T10:30:00Z"}
RESPONSE

  run bash "$CAST_BATCH_STATUS_SH" msgbatch_test456
  assert_success
  assert_output --partial "ended"
  assert_output --partial "https://storage.googleapis.com"
}

@test "status: missing ANTHROPIC_API_KEY exits 1" {
  unset ANTHROPIC_API_KEY
  run bash "$CAST_BATCH_STATUS_SH" msgbatch_test123
  assert_failure
  assert_output --partial "ANTHROPIC_API_KEY environment variable not set"
}

@test "status: missing batch_id exits 1" {
  run bash "$CAST_BATCH_STATUS_SH"
  assert_failure
}

@test "status: API error response exits 1 with error to stderr" {
  # Set mock to return invalid JSON
  cat > "${BATS_TMPDIR}/curl-response.json" <<'RESPONSE'
{"error":{"type":"invalid_request_error","message":"Batch not found"}}
RESPONSE

  run bash "$CAST_BATCH_STATUS_SH" msgbatch_invalid
  assert_failure
}
