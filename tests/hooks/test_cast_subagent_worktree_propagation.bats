#!/usr/bin/env bats
# tests/hooks/test_cast_subagent_worktree_propagation.bats
# Regression test for M-3: CAST_INPUT must propagate from stdin to sub-hooks
# via the export in cast-subagent-worktree-check.sh.

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKTREE_HOOK="$REPO_DIR/scripts/cast-subagent-worktree-check.sh"
PROTOCOL_HOOK="$REPO_DIR/scripts/cast-agent-protocol-check.sh"

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  TEST_DB="$BATS_TEST_TMPDIR/test-propagation.db"
  export CAST_DB_PATH="$TEST_DB"

  # Pre-create the agent_protocol_violations table so the sub-hook can write
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
  # Ensure CAST_INPUT is NOT set in the environment — the fix must propagate from stdin only
  unset CAST_INPUT
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

# ── Helper ────────────────────────────────────────────────────────────────────

count_violations() {
  python3 -c "
import sqlite3, os
con = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(con.execute('SELECT COUNT(*) FROM agent_protocol_violations').fetchone()[0])
con.close()
"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# Regression for M-3: piping a protocol-violation payload via stdin to the
# worktree-check harness must propagate CAST_INPUT to cast-agent-protocol-check.sh.
# Without the export, CAST_INPUT stays empty and the sub-hook silently no-ops.
@test "propagation: stdin payload flows through worktree-check to protocol-check sub-hook" {
  # Build a payload that triggers a protocol violation (prose dispatch, no tool_use)
  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'agent_type': 'code-writer',
    'agent_id': 'agent-prop-test',
    'batch_id': 1,
    'session_id': 'test-propagation',
    'agent_response': {
        'content': [{'type': 'text', 'text': 'Dispatching code-reviewer per CAST conventions.'}]
    },
}))
")"

  # Invoke the harness with the payload piped to stdin.
  # CAST_INPUT must NOT be preset — the export fix makes it available to sub-hooks.
  # We skip git worktree operations by running outside any cast worktree dir.
  run bash "$WORKTREE_HOOK" <<< "$payload"

  # The harness always exits 0
  assert_success

  # The sub-hook must have fired and logged a violation row
  local count
  count="$(count_violations)"
  [ "$count" -ge 1 ]
}

# Sanity: CAST_INPUT="" in env → sub-hook no-ops (baseline control test)
@test "propagation: empty stdin → no violation row written (no false positive)" {
  run bash "$WORKTREE_HOOK" <<< ""
  assert_success
  [ "$(count_violations)" -eq 0 ]
}
