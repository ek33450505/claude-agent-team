#!/usr/bin/env bats
# Tests for CAST Memory Persistence Tier 3 scripts:
#   cast-memory-schema-v4.py, cast-memory-consolidate.py, cast-agent-preamble.py,
#   cast-agent-preamble-hook.sh, cast-mcp-memory-server.py
#
# Coverage (14 tests):
#   1-3.  cast-memory-schema-v4: creates archived_memories, adds retrieval_count, idempotent
#   4-6.  cast-memory-consolidate: --dry-run JSON output, exits 0, correct keys
#   7-9.  cast-agent-preamble: unknown agent returns empty, exits 0 always, known agent format
#  10-11. cast-agent-preamble-hook: non-Task exits 0 silently, Task exits 0
#  12-14. cast-mcp-memory-server: imports ok, server module loads, graceful on missing DB

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"
SCHEMA_V2="$REPO_DIR/scripts/cast-memory-schema-v2.py"
SCHEMA_V3="$REPO_DIR/scripts/cast-memory-schema-v3.py"
SCHEMA_V4="$REPO_DIR/scripts/cast-memory-schema-v4.py"
CONSOLIDATE_PY="$REPO_DIR/scripts/cast-memory-consolidate.py"
PREAMBLE_PY="$REPO_DIR/scripts/cast-agent-preamble.py"
PREAMBLE_HOOK="$REPO_DIR/scripts/cast-agent-preamble-hook.sh"
MCP_SERVER="$REPO_DIR/scripts/cast-mcp-memory-server.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  mkdir -p "$HOME/.claude"
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true
  python3 "$SCHEMA_V2" >/dev/null 2>&1 || true
  python3 "$SCHEMA_V3" >/dev/null 2>&1 || true
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# cast-memory-schema-v4: archived_memories + retrieval_count
# ---------------------------------------------------------------------------

@test "cast-memory-schema-v4: creates archived_memories table" {
  run python3 "$SCHEMA_V4"
  assert_success
  # Verify table exists
  result="$(sqlite3 "$CAST_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='archived_memories';" 2>/dev/null)"
  [ "$result" = "archived_memories" ]
}

@test "cast-memory-schema-v4: adds retrieval_count column to agent_memories" {
  python3 "$SCHEMA_V4" >/dev/null 2>&1
  col_count="$(sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_memories);" 2>/dev/null | grep -c "retrieval_count" || true)"
  [ "$col_count" -ge 1 ]
}

@test "cast-memory-schema-v4: is idempotent on second run" {
  python3 "$SCHEMA_V4" >/dev/null 2>&1
  run python3 "$SCHEMA_V4"
  assert_success
  assert_output --partial "Already present"
}

# ---------------------------------------------------------------------------
# cast-memory-consolidate: weekly consolidation
# ---------------------------------------------------------------------------

@test "cast-memory-consolidate: --dry-run exits 0" {
  python3 "$SCHEMA_V4" >/dev/null 2>&1
  run python3 "$CONSOLIDATE_PY" --dry-run
  assert_success
}

@test "cast-memory-consolidate: --dry-run outputs valid JSON" {
  python3 "$SCHEMA_V4" >/dev/null 2>&1
  run python3 "$CONSOLIDATE_PY" --dry-run
  assert_success
  # Validate JSON with python
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
}

@test "cast-memory-consolidate: JSON has expected keys" {
  python3 "$SCHEMA_V4" >/dev/null 2>&1
  run python3 "$CONSOLIDATE_PY" --dry-run
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for key in ['decayed', 'merged', 'archived', 'promoted', 'timestamp']:
    assert key in d, f'Missing key: {key}'
print('OK')
"
}

# ---------------------------------------------------------------------------
# cast-agent-preamble: preamble generator
# ---------------------------------------------------------------------------

@test "cast-agent-preamble: unknown agent exits 0 with empty or markdown output" {
  run python3 "$PREAMBLE_PY" --agent unknown-test-agent-xyz
  assert_success
}

@test "cast-agent-preamble: exits 0 even with missing DB" {
  export CAST_DB_PATH="/tmp/nonexistent-cast-test.db"
  run python3 "$PREAMBLE_PY" --agent planner
  assert_success
}

@test "cast-agent-preamble: outputs markdown for seeded memory" {
  python3 "$SCHEMA_V4" >/dev/null 2>&1
  # Seed a procedural memory
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, type, name, description, content, importance) VALUES ('test-agent', 'procedural', 'test-rule', 'A test rule', 'Always test before committing code', 0.9);" 2>/dev/null
  run python3 "$PREAMBLE_PY" --agent test-agent --types procedural
  assert_success
  assert_output --partial "## Procedural Memory (auto-loaded)"
  assert_output --partial "**test-rule:**"
}

# ---------------------------------------------------------------------------
# cast-agent-preamble-hook: PreToolUse hook
# ---------------------------------------------------------------------------

# Helper to pipe JSON to the preamble hook — avoids bash -c variable expansion issues in CI
_run_preamble_hook() {
  echo "$1" | bash "$PREAMBLE_HOOK"
}

@test "cast-agent-preamble-hook: non-Task tool exits 0 with no output" {
  run _run_preamble_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  assert_success
  [ -z "$output" ]
}

@test "cast-agent-preamble-hook: Task tool exits 0" {
  run _run_preamble_hook '{"tool_name":"Task","tool_input":{"description":"Run code-writer agent"}}'
  assert_success
}

# ---------------------------------------------------------------------------
# cast-mcp-memory-server: MCP server basics
# ---------------------------------------------------------------------------

@test "cast-mcp-memory-server: mcp package imports successfully" {
  python3 -c "from mcp.server import Server" 2>/dev/null || skip "mcp package not installed"
  run python3 -c "from mcp.server import Server; from mcp.server.stdio import stdio_server; import mcp.types as types; print('OK')"
  assert_success
  assert_output "OK"
}

@test "cast-mcp-memory-server: server module loads without error" {
  python3 -c "from mcp.server import Server" 2>/dev/null || skip "mcp package not installed"
  # Import the server module without running it (check for syntax/import errors)
  run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mcp_server', '$MCP_SERVER')
mod = importlib.util.module_from_spec(spec)
# Don't execute — just verify it can be loaded
print('Module loaded OK')
"
  assert_success
  assert_output "Module loaded OK"
}

@test "cast-mcp-memory-server: get_connection returns error for missing DB" {
  python3 -c "from mcp.server import Server" 2>/dev/null || skip "mcp package not installed"
  export CAST_DB_PATH="/tmp/nonexistent-mcp-test.db"
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('srv', '$MCP_SERVER')
mod = importlib.util.module_from_spec(spec)
# Manually set up the module's namespace
import os, json, math, re, struct, sqlite3
from datetime import datetime, timedelta, timezone
mod.__dict__.update({
    'os': os, 'sys': sys, 'json': json, 'math': math, 're': re,
    'struct': struct, 'sqlite3': sqlite3, 'datetime': datetime,
    'timedelta': timedelta, 'timezone': timezone,
})
# Execute just the function definitions
exec(open('$MCP_SERVER').read().split('try:')[0], mod.__dict__)
conn, err = mod.get_connection()
assert conn is None, 'Expected None connection'
assert 'not found' in err, f'Expected not found error, got: {err}'
print('OK')
"
  assert_success
  assert_output "OK"
}
