#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="${REPO_DIR}/bin/cast"
SHIM="${REPO_DIR}/scripts/cast-managed-agent.sh"
FIXTURE_SSE="${REPO_DIR}/tests/fixtures/managed/sample-sse-response.txt"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export ORIG_PATH="$PATH"

  export HOME="$(mktemp -d)"
  export BATS_TMPDIR="${HOME}/bats-tmp"
  mkdir -p "$BATS_TMPDIR"

  MOCK_BIN_DIR="${BATS_TMPDIR}/bin"
  mkdir -p "$MOCK_BIN_DIR"
  export PATH="${MOCK_BIN_DIR}:${ORIG_PATH}"

  # Mock curl that returns configurable status + response
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

  # Block real keychain
  cat > "${MOCK_BIN_DIR}/security" <<'SEC_MOCK'
#!/bin/bash
exit 1
SEC_MOCK
  chmod +x "${MOCK_BIN_DIR}/security"

  export CAST_DB_PATH="${HOME}/.claude/cast.db"
  mkdir -p "${HOME}/.claude/logs"
}

teardown() {
  export PATH="$ORIG_PATH"
  export HOME="$ORIG_HOME"
  unset BATS_TMPDIR MOCK_BIN_DIR CAST_DB_PATH
  unset ANTHROPIC_API_KEY 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 1: cast dispatch --help exits 0 and mentions "managed"
# ---------------------------------------------------------------------------

@test "cast dispatch --help exits 0 and output contains 'managed'" {
  run bash "$CAST_BIN" dispatch --help
  assert_success
  assert_output --partial "managed"
}

# ---------------------------------------------------------------------------
# Test 2: cast dispatch --dry-run --managed prints curl command, no network call
# ---------------------------------------------------------------------------

@test "cast dispatch --dry-run --managed prints curl command without network call" {
  export ANTHROPIC_API_KEY="dummy-key-for-dry-run"
  # Poison curl: if it's actually called, it writes a sentinel file
  cat > "${MOCK_BIN_DIR}/curl" <<'POISON_CURL'
#!/bin/bash
echo "CURL_WAS_CALLED" >> "${BATS_TMPDIR}/curl-called.txt"
echo '{"id":"should_not_happen"}'
echo "__HTTP_STATUS__200"
POISON_CURL
  chmod +x "${MOCK_BIN_DIR}/curl"

  run bash "$CAST_BIN" dispatch --dry-run --managed code-reviewer "test"
  assert_success
  # Output must contain "curl"
  assert_output --partial "curl"
  # Curl must NOT have been called (no sentinel file)
  [ ! -f "${BATS_TMPDIR}/curl-called.txt" ]
}

# ---------------------------------------------------------------------------
# Test 3: cast-managed-agent.sh with invalid API key exits non-zero
# ---------------------------------------------------------------------------

@test "cast-managed-agent.sh with ANTHROPIC_API_KEY=invalid exits non-zero" {
  # Mock curl returns 401
  echo "401" > "${BATS_TMPDIR}/curl-status.txt"
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"error":{"type":"authentication_error","message":"invalid x-api-key"}}
EOF
  export ANTHROPIC_API_KEY="invalid"
  run bash "$SHIM" code-reviewer "test prompt"
  assert_failure
}

# ---------------------------------------------------------------------------
# Test 4: --no-stream flag is accepted without error (mock API success)
# ---------------------------------------------------------------------------

@test "--no-stream flag is accepted and dispatch succeeds with mocked API" {
  export ANTHROPIC_API_KEY="test-key-no-stream"
  cat > "${BATS_TMPDIR}/curl-response.json" <<'EOF'
{"id":"agent_test123","type":"agent"}
EOF
  run bash "$SHIM" code-reviewer "test prompt" --no-stream
  assert_success
}

# ---------------------------------------------------------------------------
# Test 5: SSE parser extracts text from data: lines (fixture file)
# ---------------------------------------------------------------------------

@test "SSE parser extracts text content from data: lines in fixture" {
  # Run the _parse_sse_lines logic inline via a helper script
  local parse_script="${BATS_TMPDIR}/parse_sse.sh"
  cat > "$parse_script" <<'PARSE_SCRIPT'
#!/usr/bin/env bash
# Inline the SSE parser from cast-managed-agent.sh for isolated testing
_parse_sse_lines() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "data: [DONE]" ]]; then
      continue
    fi
    if [[ "$line" == data:* ]]; then
      local payload="${line#data: }"
      local text
      text="$(echo "$payload" | python3 -c '
import json, sys
try:
    obj = json.load(sys.stdin)
    delta = obj.get("delta", {})
    t = delta.get("text", "")
    if t:
        print(t, end="")
except Exception:
    pass
' 2>/dev/null || true)"
      printf '%s' "$text"
    fi
  done
}

_parse_sse_lines < "$1"
PARSE_SCRIPT
  chmod +x "$parse_script"

  run bash "$parse_script" "$FIXTURE_SSE"
  assert_success
  assert_output --partial "Review complete."
  assert_output --partial "Status: DONE"
}
