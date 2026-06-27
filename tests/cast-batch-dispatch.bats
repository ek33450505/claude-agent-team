#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BATCH_DISPATCH_SH="$REPO_DIR/scripts/cast-batch-dispatch.sh"

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

@test "dispatch: does not create batch_dispatches table in cast.db" {
  # Regression guard: the batch_dispatches table was dropped in Wave-3 Inc 2.
  # Verify the writer no longer re-accretes it.
  run bash "$CAST_BATCH_DISPATCH_SH" commit "$PROMPT_FILE"
  assert_success

  # If no DB was created at all, the table obviously doesn't exist — pass.
  if [ ! -f "$CAST_DB_PATH" ]; then
    return 0
  fi

  python3 - "$CAST_DB_PATH" <<'PYEOF'
import sys, sqlite3
db_path = sys.argv[1]
try:
  conn = sqlite3.connect(db_path)
  rows = conn.execute(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='batch_dispatches'"
  ).fetchall()
  conn.close()
  if rows:
    print("FAIL: batch_dispatches table exists")
    sys.exit(1)
  else:
    print("OK: batch_dispatches table absent")
    sys.exit(0)
except Exception as e:
  print(f"ERROR: {e}")
  sys.exit(1)
PYEOF
}
