#!/usr/bin/env bats
# tests/cast-mcp-cmd.bats — Integration tests for `cast mcp` subcommand (v9 F4 Unit 2)
#
# HARD RULES:
#   - Temp-HOME isolated via setup_temp_home / teardown_temp_home (NEVER touch real ~/.claude)
#   - env CAST_DB_PATH=... form for passing env (NOT `run VAR=val cmd` → 127)
#   - DB seeded via cast-db-init.sh in setup()
#   - Frame piping via printf (not heredoc — BATS rewrites heredoc @test lines)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"
SERVER_PY="$REPO_DIR/scripts/cast-mcp-server.py"

setup() {
  load 'helpers/setup'
  setup_temp_home

  export CAST_DB_PATH="$HOME/.claude/cast-mcp-cmd-test.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CAST_REPO_DIR="$REPO_DIR"
  mkdir -p "$(dirname "$CAST_DB_PATH")"

  # Initialize DB schema (required for cast mcp status handshake)
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH CAST_SCRIPTS_DIR CAST_REPO_DIR
}

# -----------------------------------------------------------------------
# 1. cast mcp config → output contains cast-record, stdio, claude mcp add
# -----------------------------------------------------------------------
@test "cast mcp config prints cast-record" {
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash "$CAST_BIN" mcp config
  assert_success
  assert_output --partial 'cast-record'
}

@test "cast mcp config prints stdio" {
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash "$CAST_BIN" mcp config
  assert_success
  assert_output --partial 'stdio'
}

@test "cast mcp config prints claude mcp add line" {
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash "$CAST_BIN" mcp config
  assert_success
  assert_output --partial 'claude mcp add'
}

# -----------------------------------------------------------------------
# 2. cast mcp --help and bare `cast mcp` → usage lists serve/config/status
# -----------------------------------------------------------------------
@test "cast mcp help lists serve config status" {
  # Note: --help is intercepted by the global flag parser (shows global usage).
  # The subcommand-level help is reached via 'cast mcp help' (no dashes).
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash "$CAST_BIN" mcp help
  assert_success
  assert_output --partial 'serve'
  assert_output --partial 'config'
  assert_output --partial 'status'
}

@test "bare cast mcp prints usage" {
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash "$CAST_BIN" mcp
  assert_success
  assert_output --partial 'usage: cast mcp'
}

# -----------------------------------------------------------------------
# 3. cast mcp status with seeded DB → exit 0 and handshake OK
# -----------------------------------------------------------------------
@test "cast mcp status exits 0 and reports handshake OK" {
  # DB is seeded in setup(); server resolves via CAST_SCRIPTS_DIR
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash "$CAST_BIN" mcp status
  assert_success
  assert_output --partial 'handshake OK'
}

# -----------------------------------------------------------------------
# 4. End-to-end serve: piping initialize through `cast mcp serve`
#    proves the dispatch wires all the way through to the Python server
# -----------------------------------------------------------------------
@test "cast mcp serve responds to initialize with protocolVersion 2025-06-18" {
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash -c \
    "printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}' | bash '$CAST_BIN' mcp serve"
  assert_success
  assert_output --partial '2025-06-18'
}

# -----------------------------------------------------------------------
# 5. Unknown subcommand → non-zero exit
# -----------------------------------------------------------------------
@test "cast mcp bogus exits non-zero" {
  run env CAST_DB_PATH="$CAST_DB_PATH" CAST_SCRIPTS_DIR="$CAST_SCRIPTS_DIR" CAST_REPO_DIR="$CAST_REPO_DIR" bash "$CAST_BIN" mcp bogus
  assert_failure
}
