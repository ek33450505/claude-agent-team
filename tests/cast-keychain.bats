#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_KEYCHAIN_SH="$REPO_DIR/scripts/cast-keychain.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run "$@" with a hard timeout (seconds). Returns the command's exit code, or
# non-zero if it had to be killed (e.g. a Keychain GUI prompt blocked it).
_kc_run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    return $?
  fi
  # Portable fallback: background the command, watchdog kills it after $secs.
  "$@" &
  local cmd_pid=$!
  (
    sleep "$secs"
    kill -TERM "$cmd_pid" 2>/dev/null || true
  ) &
  local wd_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -TERM "$wd_pid" 2>/dev/null || true
  wait "$wd_pid" 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  # Skip all tests on non-macOS platforms
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "macOS only — Keychain not available"
  fi
}

teardown() {
  # Clean up any test Keychain entries
  security delete-generic-password -s "cast-test-bats-key" -a cast 2>/dev/null || true
  security delete-generic-password -s "cast-test-bats-probe" -a cast 2>/dev/null || true
}

require_keychain_writes() {
  # A Keychain authorization prompt blocks forever in automated runs; the timeout
  # makes that degrade to a skip (the guard's original intent) instead of hanging.
  if ! _kc_run_with_timeout 5 security add-generic-password -U -s "cast-test-bats-probe" -a cast -w "probe" 2>/dev/null; then
    skip "Keychain writes unavailable in this environment (or auth prompt timed out)"
  fi
  security delete-generic-password -s "cast-test-bats-probe" -a cast 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "cast-keychain.sh: no args prints usage and exits 1" {
  run bash "$CAST_KEYCHAIN_SH"
  assert_failure
  assert_output --partial "Usage:"
}

@test "cast-keychain.sh: --help prints usage and exits 0" {
  run bash "$CAST_KEYCHAIN_SH" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Commands:"
}

@test "cast-keychain.sh: unknown command exits 1" {
  run bash "$CAST_KEYCHAIN_SH" bogus
  assert_failure
  assert_output --partial "Unknown command"
}

@test "cast-keychain.sh: set requires service and secret" {
  run bash "$CAST_KEYCHAIN_SH" set
  assert_failure
  assert_output --partial "requires"
}

@test "cast-keychain.sh: get for nonexistent key returns error" {
  run bash "$CAST_KEYCHAIN_SH" get "nonexistent-key-$$"
  assert_failure
  assert_output --partial "No Keychain entry found"
}

@test "cast-keychain.sh: set/get cycle round-trips a secret" {
  require_keychain_writes

  run bash "$CAST_KEYCHAIN_SH" set "test-bats-key" "hello-from-bats"
  assert_success
  assert_output --partial "Stored secret"

  run bash "$CAST_KEYCHAIN_SH" get "test-bats-key"
  assert_success
  assert_output "hello-from-bats"
}

@test "cast-keychain.sh: delete removes a stored key" {
  require_keychain_writes

  # Store a key first
  bash "$CAST_KEYCHAIN_SH" set "test-bats-key" "to-be-deleted" 2>/dev/null

  run bash "$CAST_KEYCHAIN_SH" delete "test-bats-key"
  assert_success
  assert_output --partial "Deleted"

  # Verify it's gone
  run bash "$CAST_KEYCHAIN_SH" get "test-bats-key"
  assert_failure
}

@test "cast-keychain.sh: status output includes ANTHROPIC_API_KEY" {
  run bash "$CAST_KEYCHAIN_SH" status
  assert_success
  assert_output --partial "ANTHROPIC_API_KEY"
}

@test "cast-keychain.sh: list output has header" {
  run bash "$CAST_KEYCHAIN_SH" list
  assert_success
  assert_output --partial "CAST Keychain Entries"
}
