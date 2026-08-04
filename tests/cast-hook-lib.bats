#!/usr/bin/env bats
# Tests for scripts/cast-hook-lib.sh
# Covers: cast_hook_read_stdin (empty, piped input), cast_hook_db_path (CAST_DB_PATH override, fallback)
# and re-source guard (_CAST_HOOK_LIB_LOADED).
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_LIB="$REPO_DIR/scripts/cast-hook-lib.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude"
}

teardown() {
  teardown_temp_home
}

# --- cast_hook_read_stdin: piped input ---

@test "cast_hook_read_stdin captures piped input" {
  run bash -c "source '$HOOK_LIB'; cast_hook_read_stdin; echo \"\$INPUT\"" <<< 'hello'
  assert_success
  assert_output "hello"
}

@test "cast_hook_read_stdin handles multiline input" {
  run bash -c "source '$HOOK_LIB'; cast_hook_read_stdin; echo \"\$INPUT\"" <<< $'line1\nline2'
  assert_success
  assert_output "line1
line2"
}

# --- cast_hook_read_stdin: empty/closed stdin ---

@test "cast_hook_read_stdin with empty stdin sets INPUT to empty string" {
  run bash -c ". '$HOOK_LIB'; printf '' | cast_hook_read_stdin; echo \"[\$INPUT]\""
  assert_success
  assert_output "[]"
}

@test "cast_hook_read_stdin exits 0 on closed stdin (never aborts)" {
  run bash -c ". '$HOOK_LIB'; cast_hook_read_stdin </dev/null; echo ok"
  assert_success
  assert_output "ok"
}

# --- cast_hook_db_path: CAST_DB_PATH override ---

@test "cast_hook_db_path uses CAST_DB_PATH when set" {
  run bash -c "export CAST_DB_PATH='/custom/path.db'; . '$HOOK_LIB'; cast_hook_db_path; echo \"\$DB_PATH\""
  assert_success
  assert_output "/custom/path.db"
}

# --- cast_hook_db_path: fallback to HOME ---

@test "cast_hook_db_path falls back to \$HOME/.claude/cast.db when CAST_DB_PATH unset" {
  run bash -c "unset CAST_DB_PATH; . '$HOOK_LIB'; cast_hook_db_path; echo \"\$DB_PATH\""
  assert_success
  assert_output "$HOME/.claude/cast.db"
}

# --- Re-source guard ---

@test "re-sourcing cast-hook-lib.sh returns early and keeps functions defined" {
  run bash -c "
    . '$HOOK_LIB'
    old_func=\"\$(declare -f cast_hook_read_stdin)\"
    . '$HOOK_LIB'  # second source
    new_func=\"\$(declare -f cast_hook_read_stdin)\"
    [[ \"\$old_func\" == \"\$new_func\" ]] && echo 'functions identical'
  "
  assert_success
  assert_output "functions identical"
}

@test "sourcing multiple times does not error" {
  run bash -c "
    . '$HOOK_LIB'
    . '$HOOK_LIB'
    . '$HOOK_LIB'
    echo 'ok'
  "
  assert_success
  assert_output "ok"
}
