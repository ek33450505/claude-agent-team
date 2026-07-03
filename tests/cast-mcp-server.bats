#!/usr/bin/env bats
# tests/cast-mcp-server.bats — Offline frame-piping tests for cast-mcp-server.py (v9 F4)
#
# HARD RULES:
#   - Temp-HOME isolated via setup_temp_home / teardown_temp_home (NEVER touch real ~/.claude)
#   - Frame piping via printf (not heredoc — BATS rewrites heredoc @test lines)
#   - DB seeded via cast-db-init.sh + sqlite3 INSERTs in setup()
#   - env CAST_DB_PATH=... form for passing env to server (NOT run VAR=val cmd → 127)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SERVER_PY="$REPO_DIR/scripts/cast-mcp-server.py"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home

  export CAST_DB_PATH="$HOME/.claude/cast-test.db"
  mkdir -p "$(dirname "$CAST_DB_PATH")"

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1

  # Seed test rows (canonical sessions columns only — matches fresh cast-db-init.sh schema,
  # so the test exercises the real fresh-install path, not an ALTER-faked live shape).
  sqlite3 "$CAST_DB_PATH" "INSERT OR IGNORE INTO sessions (id, project, project_root, started_at, ended_at, status, deleted_at) VALUES ('sess-001', 'claude-agent-team', '/tmp/repo', '2026-06-30T00:00:00Z', NULL, 'active', NULL);"

  sqlite3 "$CAST_DB_PATH" "INSERT OR IGNORE INTO dispatch_decisions (id, session_id, prompt_snippet, chosen_agent, model, created_at, outcome) VALUES (1, 'sess-001', 'test prompt snippet', 'code-writer', 'claude-sonnet-4-6', '2026-06-30T00:00:00Z', 'success');"

  sqlite3 "$CAST_DB_PATH" "INSERT OR IGNORE INTO incidents (id, occurred_at, problem_summary, fix_summary, related_files, related_commit, resolution_status, surfaced_by) VALUES ('inc-001', '2026-06-30T00:00:00Z', 'test problem happened', 'test fix applied', 'scripts/foo.py', 'abc1234', 'closed', 'code-writer');"

  sqlite3 "$CAST_DB_PATH" "INSERT OR IGNORE INTO agent_runs (session_id, agent, model, started_at, ended_at, status, cost_usd, input_tokens, output_tokens) VALUES ('sess-001', 'code-writer', 'claude-sonnet-4-6', '2026-06-30T00:00:00Z', '2026-06-30T00:01:00Z', 'done', 0.005, 800, 300);"
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH
}

# -----------------------------------------------------------------------
# (a) initialize → protocolVersion 2025-06-18 + serverInfo.name cast-record
# -----------------------------------------------------------------------
@test "initialize returns protocolVersion 2025-06-18" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial '2025-06-18'
}

@test "initialize returns serverInfo.name cast-record" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'cast-record'
}

# -----------------------------------------------------------------------
# (b) tools/list → all 5 tool names present
# -----------------------------------------------------------------------
@test "tools/list returns all 5 tool names" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'cast_decisions'
  assert_output --partial 'cast_incidents'
  assert_output --partial 'cast_cost'
  assert_output --partial 'cast_sessions'
  assert_output --partial 'cast_ask'
}

# -----------------------------------------------------------------------
# (c) tools/call cast_decisions → seeded row appears
# -----------------------------------------------------------------------
@test "cast_decisions returns seeded dispatch decision row" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_decisions\",\"arguments\":{\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'code-writer'
  assert_output --partial 'test prompt snippet'
}

# -----------------------------------------------------------------------
# (d) tools/call cast_cost by=agent → returns rows
# -----------------------------------------------------------------------
@test "cast_cost by=agent returns seeded agent run" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_cost\",\"arguments\":{\"by\":\"agent\",\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'code-writer'
  assert_output --partial 'cost_usd'
}

@test "cast_cost by=session returns grouped rows" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_cost\",\"arguments\":{\"by\":\"session\",\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'session_id'
}

# -----------------------------------------------------------------------
# (e) cast_ask — graceful handling (FTS5 may or may not be populated)
# -----------------------------------------------------------------------
@test "cast_ask with valid query returns non-empty response" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_ask\",\"arguments\":{\"query\":\"test\",\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  # Either returns rows (starting with digit) or honest "unavailable" — both are non-crash responses
  assert_output --partial 'content'
}

@test "cast_ask with empty query returns error text" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_ask\",\"arguments\":{\"query\":\"\",\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'required'
}

# -----------------------------------------------------------------------
# (f) resources/list → 5 uris; resources/read cast://schema contains table name
# -----------------------------------------------------------------------
@test "resources/list returns all 5 resource uris" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/list\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'cast://schema'
  assert_output --partial 'cast://decisions/recent'
  assert_output --partial 'cast://incidents/recent'
  assert_output --partial 'cast://cost/summary'
  assert_output --partial 'cast://sessions/recent'
}

@test "resources/read cast://schema returns table listing with row counts" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/read\",\"params\":{\"uri\":\"cast://schema\"}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'dispatch_decisions'
  assert_output --partial 'rows'
}

@test "resources/read unknown uri returns error -32602" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/read\",\"params\":{\"uri\":\"cast://nonexistent\"}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial '-32602'
  assert_output --partial 'Unknown resource'
}

# -----------------------------------------------------------------------
# (g) unknown method → error code -32601
# -----------------------------------------------------------------------
@test "unknown method returns error -32601" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"no_such_method\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial '-32601'
  assert_output --partial 'Method not found'
}

# -----------------------------------------------------------------------
# (h) notification frame (no id) → produces NO stdout output
# -----------------------------------------------------------------------
@test "notification frame without id produces no stdout" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output ''
}

# -----------------------------------------------------------------------
# (i) DB-absent: nonexistent path → honest "unavailable", no crash / no traceback
# -----------------------------------------------------------------------
@test "DB-absent: cast_decisions returns unavailable text without traceback" {
  local absent_path="$BATS_TEST_TMPDIR/nonexistent.db"
  run env CAST_DB_PATH="$absent_path" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_decisions\",\"arguments\":{}}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'unavailable'
  refute_output --partial 'Traceback'
}

@test "DB-absent: server handles ping cleanly (exit 0)" {
  local absent_path="$BATS_TEST_TMPDIR/nonexistent.db"
  run env CAST_DB_PATH="$absent_path" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"ping\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial '"result": {}'
}

# -----------------------------------------------------------------------
# (j) ping → empty result
# -----------------------------------------------------------------------
@test "ping returns empty result object" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"ping\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial '"result": {}'
}

# -----------------------------------------------------------------------
# (k) invalid JSON → parse-error code -32700, server continues processing
# -----------------------------------------------------------------------
@test "invalid JSON line emits parse-error -32700 then server continues" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n%s\n' 'NOT_JSON' '{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"ping\",\"params\":{}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial '-32700'
  # Server continues and handles the ping after the bad line
  assert_output --partial '"result": {}'
}

# -----------------------------------------------------------------------
# (T-C1) cast_cost by=branch — cast-db-init.sh adds branch unconditionally
# so expect normal row result, NOT the "unavailable" fallback
# -----------------------------------------------------------------------
@test "cast_cost by=branch returns rows (branch column present on fresh init)" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_cost\",\"arguments\":{\"by\":\"branch\",\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  # branch IS present (cast-db-init.sh adds it unconditionally at line 684);
  # seeded row has NULL branch → COALESCE gives '(none)'.
  refute_output --partial 'unavailable'
  assert_output --partial 'cost_usd'
}

# -----------------------------------------------------------------------
# (T-C2) cast_ask FTS5-absent path — explicit "full-text index unavailable"
# -----------------------------------------------------------------------
@test "cast_ask returns full-text index unavailable when record_fts is dropped" {
  # Drop the FTS table from the test DB before the server runs
  sqlite3 "$CAST_DB_PATH" "DROP TABLE IF EXISTS record_fts;"
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_ask\",\"arguments\":{\"query\":\"test\",\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'full-text index unavailable'
}

# -----------------------------------------------------------------------
# (T-C3) cast_sessions schema completeness — canonical field project_root present
# -----------------------------------------------------------------------
@test "cast_sessions returns canonical session fields including project_root" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_sessions\",\"arguments\":{\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial 'project_root'
  assert_output --partial 'sess-001'
}

# -----------------------------------------------------------------------
# (S-L3) incidents search with literal % metacharacter — no crash, 0 rows
# -----------------------------------------------------------------------
@test "cast_incidents with literal percent in query returns gracefully" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_incidents\",\"arguments\":{\"query\":\"100%\",\"limit\":5}}}' | python3 '$SERVER_PY'"
  assert_success
  # 0 rows — seeded incident has no "100%" in summary
  assert_output --partial '0 rows'
  refute_output --partial 'Traceback'
  refute_output --partial 'error'
}

# -----------------------------------------------------------------------
# (U3-F1) conn-leak: failing tool call returns proper error and server
# continues to serve the next request (verifies contextlib.closing guard)
# -----------------------------------------------------------------------
@test "conn-leak: failing tool call returns error then server continues serving" {
  # Drop incidents table so _fetch_incidents raises OperationalError mid-flight.
  # Then immediately send a ping — the server must handle it cleanly (no crash,
  # no leaked-connection hang), proving the finally/closing guard works.
  sqlite3 "$CAST_DB_PATH" "DROP TABLE IF EXISTS incidents;"
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n%s\n' \
    '{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"cast_incidents\",\"arguments\":{}}}' \
    '{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"ping\",\"params\":{}}' \
    | python3 '$SERVER_PY'"
  assert_success
  # First response: honest "unavailable" (no traceback)
  assert_output --partial 'unavailable'
  refute_output --partial 'Traceback'
  # Second response: server still alive and answers ping
  assert_output --partial '"result": {}'
}

# -----------------------------------------------------------------------
# (U3-F2) unknown tool → JSON-RPC error -32602, NOT isError-in-content
# -----------------------------------------------------------------------
@test "unknown tool name returns JSON-RPC protocol error -32602" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/call\",\"params\":{\"name\":\"nonexistent_tool\",\"arguments\":{}}}' | python3 '$SERVER_PY'"
  assert_success
  # Must be a top-level JSON-RPC error object with code -32602
  assert_output --partial '-32602'
  assert_output --partial 'Unknown tool'
  assert_output --partial '"error"'
  # Must NOT be an isError-in-content result (those have "content" + "isError" at top)
  refute_output --partial 'isError'
}

# -----------------------------------------------------------------------
# (U3-F3) initialize: honor client protocolVersion negotiation
# -----------------------------------------------------------------------
@test "initialize echoes matching client protocolVersion" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}' | python3 '$SERVER_PY'"
  assert_success
  assert_output --partial '2025-06-18'
}

@test "initialize returns server version for mismatched client protocolVersion" {
  run env CAST_DB_PATH="$CAST_DB_PATH" bash -c "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"9999-99-99\"}}' | python3 '$SERVER_PY'"
  assert_success
  # Server version returned, not the unknown client version
  assert_output --partial '2025-06-18'
  refute_output --partial '9999-99-99'
}
