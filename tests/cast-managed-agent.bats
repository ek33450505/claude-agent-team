#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SHIM="${REPO_DIR}/scripts/cast-managed-agent.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  export ORIG_PATH="$PATH"

  export BATS_TMPDIR="${HOME}/bats-tmp"
  mkdir -p "$BATS_TMPDIR"

  MOCK_BIN_DIR="${BATS_TMPDIR}/bin"
  mkdir -p "$MOCK_BIN_DIR"
  export PATH="${MOCK_BIN_DIR}:${ORIG_PATH}"

  # Mock curl: reads status from curl-status.txt (default 200), response from curl-response.json
  cat > "${MOCK_BIN_DIR}/curl" <<'CURL_MOCK'
#!/bin/bash
RESPONSE_FILE="${BATS_TMPDIR}/curl-response.json"
STATUS_FILE="${BATS_TMPDIR}/curl-status.txt"
STATUS=200
[ -f "$STATUS_FILE" ] && STATUS="$(cat "$STATUS_FILE")"
if [ -f "$RESPONSE_FILE" ]; then
  cat "$RESPONSE_FILE"
else
  echo '{"id":"agent_test123","type":"agent"}'
fi
echo ""
echo "__HTTP_STATUS__${STATUS}"
CURL_MOCK
  chmod +x "${MOCK_BIN_DIR}/curl"

  # Block real keychain access — replace `security` with a no-op that exits 1
  cat > "${MOCK_BIN_DIR}/security" <<'SEC_MOCK'
#!/bin/bash
exit 1
SEC_MOCK
  chmod +x "${MOCK_BIN_DIR}/security"

  # Set DB path into temp home so tests don't touch real cast.db
  export CAST_DB_PATH="${HOME}/.claude/cast.db"
  mkdir -p "${HOME}/.claude/logs"
}

teardown() {
  export PATH="$ORIG_PATH"
  unset BATS_TMPDIR MOCK_BIN_DIR CAST_DB_PATH
  unset ANTHROPIC_API_KEY 2>/dev/null || true
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

@test "missing API key + no keychain → exits 2" {
  unset ANTHROPIC_API_KEY
  run bash "$SHIM" test-agent "do something"
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "ANTHROPIC_API_KEY"
}

@test "401 fail-closed even with --local-fallback" {
  export ANTHROPIC_API_KEY="test-key-12345"
  echo "401" > "${BATS_TMPDIR}/curl-status.txt"
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"error":{"type":"authentication_error","message":"invalid x-api-key"}}
EOF
  run bash "$SHIM" test-agent "do something" --local-fallback
  assert_failure
  assert_output --partial "authentication failure"
}

@test "403 fail-closed even with --local-fallback" {
  export ANTHROPIC_API_KEY="test-key-12345"
  echo "403" > "${BATS_TMPDIR}/curl-status.txt"
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"error":{"type":"permission_error","message":"permission denied"}}
EOF
  run bash "$SHIM" test-agent "do something" --local-fallback
  assert_failure
  assert_output --partial "authentication failure"
}

@test "success path 200 (full flow) → exits 0 with stdout" {
  export ANTHROPIC_API_KEY="test-key-12345"
  # All three curl calls will use this response (agent, env, session all return id)
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"id":"agent_test123","type":"agent"}
EOF
  run bash "$SHIM" test-agent "do something"
  assert_success
  [ -n "$output" ]
}

@test "success path 200 (full flow) → stdout is non-empty without relying on stderr" {
  # Regression test for Phase 6b utcnow→timezone-aware fix:
  # Prior to the script fix, the only output was a Python DeprecationWarning on stderr
  # (from datetime.utcnow()). BATS `run` captures both streams into $output, so the
  # test appeared to pass. After removing utcnow() the warning disappeared and $output
  # became empty. The script must emit real stdout content on the streaming success path.
  export ANTHROPIC_API_KEY="test-key-12345"
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"id":"agent_test123","type":"agent"}
EOF
  run bash "$SHIM" test-agent "do something"
  assert_success
  # Capture stdout only (not stderr) to verify real stdout output exists
  stdout_only="$(bash "$SHIM" test-agent "do something" 2>/dev/null)"
  [ -n "$stdout_only" ]
}

@test "--define-only mode → exits 0" {
  export ANTHROPIC_API_KEY="test-key-12345"
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"id":"agent_test123","type":"agent"}
EOF
  run bash "$SHIM" test-agent "do something" --define-only
  assert_success
}

@test "no args → exits 2 with Usage" {
  export ANTHROPIC_API_KEY="test-key-12345"
  run bash "$SHIM"
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "Usage"
}

@test "CAST_MANAGED_AGENT_BETA_HEADER env override is accepted" {
  export ANTHROPIC_API_KEY="test-key-12345"
  export CAST_MANAGED_AGENT_BETA_HEADER="managed-agents-test"
  # --define-only exits after the first curl call (agent definition).
  # The mock curl returns HTTP 200 with a valid id so the shim succeeds.
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"id":"agent_test123","type":"agent"}
EOF
  run bash "$SHIM" test-agent "do something" --define-only
  assert_success
  unset CAST_MANAGED_AGENT_BETA_HEADER
}
