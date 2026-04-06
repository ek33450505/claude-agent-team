#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_ENCRYPT_SH="$REPO_DIR/scripts/cast-encrypt.sh"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "cast-encrypt.sh: no args prints usage and exits 1" {
  run bash "$CAST_ENCRYPT_SH"
  assert_failure
  assert_output --partial "Usage:"
}

@test "cast-encrypt.sh: --help prints usage and exits 0" {
  run bash "$CAST_ENCRYPT_SH" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Commands:"
}

@test "cast-encrypt.sh: unknown command exits 1" {
  run bash "$CAST_ENCRYPT_SH" bogus
  assert_failure
  assert_output --partial "Unknown command"
}

@test "cast-encrypt.sh: status reports age availability" {
  run bash "$CAST_ENCRYPT_SH" status
  # Should succeed regardless of age being installed
  assert_output --partial "CAST Encryption Status"
  assert_output --partial "age:"
}

@test "cast-encrypt.sh: status reports memory state" {
  run bash "$CAST_ENCRYPT_SH" status
  assert_output --partial "Memory state:"
}

@test "cast-encrypt.sh: encrypt without setup fails" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  # Use a temp home so no real keys exist
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/agent-memory-local"

  run bash "$CAST_ENCRYPT_SH" encrypt
  assert_failure
  assert_output --partial "No public key found"

  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

@test "cast-encrypt.sh: setup generates keypair when age is installed" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/config"

  run bash "$CAST_ENCRYPT_SH" setup
  assert_success
  assert_output --partial "Keypair generated"

  # Verify public key was created
  [ -f "$HOME/.claude/cast-security.pub" ]

  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}
