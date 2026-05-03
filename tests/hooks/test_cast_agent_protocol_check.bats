#!/usr/bin/env bats
# tests/hooks/test_cast_agent_protocol_check.bats
# Covers: scripts/cast-agent-protocol-check.sh

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK="$REPO_DIR/scripts/cast-agent-protocol-check.sh"

# ── Payload helpers ──────────────────────────────────────────────────────────

make_payload() {
  local agent_type="${1:-code-writer}"
  local text="${2:-Status: DONE}"
  local has_tool_use="${3:-false}"
  python3 -c "
import json, sys
agent_type = sys.argv[1]
text = sys.argv[2]
has_tool_use = sys.argv[3] == 'true'
content = [{'type': 'text', 'text': text}]
if has_tool_use:
    content.append({'type': 'tool_use', 'id': 'tu_001', 'name': 'Agent', 'input': {}})
print(json.dumps({
    'agent_type': agent_type,
    'agent_id': 'agent-test-001',
    'batch_id': 1,
    'session_id': 'test-session-proto',
    'agent_response': {'content': content},
}))
" "$agent_type" "$text" "$has_tool_use"
}

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  TEST_DB="$BATS_TEST_TMPDIR/test-proto.db"
  export CAST_DB_PATH="$TEST_DB"

  python3 - <<'PYEOF'
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS agent_protocol_violations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT, agent_type TEXT NOT NULL,
  agent_id TEXT, batch_id INTEGER,
  violation TEXT NOT NULL, pattern TEXT,
  timestamp TEXT NOT NULL, raw_excerpt TEXT
)''')
con.commit(); con.close()
PYEOF

  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

# ── Helper: count rows in agent_protocol_violations ──────────────────────────

count_violations() {
  python3 -c "
import sqlite3, os
con = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(con.execute('SELECT COUNT(*) FROM agent_protocol_violations').fetchone()[0])
con.close()
"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. CLAUDE_SUBPROCESS=1 → exits 0 silently, no DB write
@test "protocol-check: CLAUDE_SUBPROCESS=1 exits 0 silently, no row written" {
  local payload
  payload="$(make_payload 'code-writer' 'Dispatching code-reviewer per CAST.')"
  CLAUDE_SUBPROCESS=1 CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  assert_output ""
  [ "$(count_violations)" -eq 0 ]
}

# 2. Prose-dispatch payload with no tool_use → violation row + stderr warning
@test "protocol-check: prose dispatch text with no tool_use → row in agent_protocol_violations + stderr warning" {
  local payload
  payload="$(make_payload 'code-writer' 'Dispatching code-reviewer per CAST conventions.')"
  CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  assert_output --partial "[CAST-WARN]"
  [ "$(count_violations)" -eq 1 ]
}

# 3. Prose-dispatch payload WITH matching tool_use → no row, no warning
@test "protocol-check: prose dispatch text WITH tool_use → no violation row" {
  local payload
  payload="$(make_payload 'code-writer' 'Dispatching code-reviewer per CAST.' 'true')"
  CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  refute_output --partial "[CAST-WARN]"
  [ "$(count_violations)" -eq 0 ]
}

# 4. Mid-sentence "dispatching" (not line-anchored) → no row (line-anchor works)
@test "protocol-check: mid-sentence 'dispatching' word is not line-anchored → no violation" {
  local text="The function for dispatching requests handles routing logic. Status: DONE"
  local payload
  payload="$(make_payload 'code-writer' "$text")"
  CAST_INPUT="$payload" run bash "$HOOK" <<< ""
  assert_success
  refute_output --partial "[CAST-WARN]"
  [ "$(count_violations)" -eq 0 ]
}

# 5. Empty CAST_INPUT → exits 0, no row
@test "protocol-check: empty CAST_INPUT → exits 0, no row" {
  CAST_INPUT="" run bash "$HOOK" <<< ""
  assert_success
  [ "$(count_violations)" -eq 0 ]
}
