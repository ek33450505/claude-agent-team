#!/usr/bin/env bats
# tests/hooks/test_cast_truncation_check.bats
# Covers: scripts/cast-truncation-check.sh

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK="$REPO_DIR/scripts/cast-truncation-check.sh"

# ── Payload helpers ──────────────────────────────────────────────────────────

make_payload() {
  local agent_type="${1:-security}"
  local text="${2:-Status: DONE}"
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type': sys.argv[1],
    'agent_id': 'trunc-test-001',
    'batch_id': 1,
    'session_id': 'test-session-trunc',
    'agent_response': {'content': [{'type': 'text', 'text': sys.argv[2]}]},
}))
" "$agent_type" "$text"
}

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  TEST_DB="$BATS_TEST_TMPDIR/test-trunc.db"
  export CAST_DB_PATH="$TEST_DB"

  python3 - <<'PYEOF'
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS agent_truncations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT, agent_type TEXT NOT NULL,
  agent_id TEXT, batch_id INTEGER,
  last_line TEXT, timestamp TEXT NOT NULL,
  char_count INTEGER, has_status INTEGER DEFAULT 0,
  has_json INTEGER DEFAULT 0
)''')
con.commit(); con.close()
PYEOF

  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

# ── Helper ────────────────────────────────────────────────────────────────────

count_truncations() {
  python3 -c "
import sqlite3, os
con = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(con.execute('SELECT COUNT(*) FROM agent_truncations').fetchone()[0])
con.close()
"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. CLAUDE_SUBPROCESS=1 → exits 0 silently
@test "truncation-check: CLAUDE_SUBPROCESS=1 exits 0 silently" {
  local payload
  payload="$(make_payload 'security' 'Reviewing auth flow in detail...')"
  CLAUDE_SUBPROCESS=1 CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  assert_output ""
  [ "$(count_truncations)" -eq 0 ]
}

# 2. Response with no Status block AND no JSON status → row + stderr warning
@test "truncation-check: no Status block + no JSON status block → row in agent_truncations + stderr warning" {
  local long_text="Checking all files in the repository. The implementation looks fine so far. Authentication flow is correct."
  local payload
  payload="$(make_payload 'security' "$long_text")"
  CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  assert_output --partial "[CAST-TRUNCATED]"
  [ "$(count_truncations)" -eq 1 ]
}

# 3. Response with prose 'Status: DONE' → exits 0, no row
@test "truncation-check: response with 'Status: DONE' → no row, no warning" {
  local text="Reviewing the authentication flow carefully. The implementation looks solid.

Status: DONE
Summary: Security review complete, no issues found."
  local payload
  payload="$(make_payload 'security' "$text")"
  CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  [ "$(count_truncations)" -eq 0 ]
}

# 4. Response with JSON status block → exits 0, no row
@test "truncation-check: response with JSON status block → no row" {
  local text
  # Use printf to avoid heredoc backtick escaping issues in BATS
  text="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    'Completed reviewing all files. Changes look good and everything passes.' \
    '' \
    '```json status' \
    '{' \
    '  "schema_version": "1.0",' \
    '  "status": "DONE",' \
    '  "agent": "security"' \
    '}' \
    '```')"
  local payload
  payload="$(make_payload 'security' "$text")"
  CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  [ "$(count_truncations)" -eq 0 ]
}

# 5. Trivial response (< 50 chars) → exits 0, no row
@test "truncation-check: trivial response under 50 chars → no row" {
  local payload
  payload="$(make_payload 'security' 'Ok.')"
  CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  refute_output --partial "[CAST-TRUNCATED]"
  [ "$(count_truncations)" -eq 0 ]
}
