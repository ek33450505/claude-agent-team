#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_OLLAMA_SH="$REPO_DIR/scripts/cast-ollama.sh"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "cast-ollama.sh: no args prints usage and exits 1" {
  run bash "$CAST_OLLAMA_SH"
  assert_failure
  assert_output --partial "Usage:"
}

@test "cast-ollama.sh: --help prints usage and exits 0" {
  run bash "$CAST_OLLAMA_SH" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Commands:"
}

@test "cast-ollama.sh: unknown command exits 1" {
  run bash "$CAST_OLLAMA_SH" bogus
  assert_failure
  assert_output --partial "Unknown command"
}

@test "cast-ollama.sh: query requires prompt argument" {
  run bash "$CAST_OLLAMA_SH" query
  assert_failure
  assert_output --partial "requires a prompt"
}

@test "cast-ollama.sh: classify requires prompt argument" {
  run bash "$CAST_OLLAMA_SH" classify
  assert_failure
  assert_output --partial "requires a prompt"
}

@test "cast-ollama.sh: status checks for ollama installation" {
  if ! command -v ollama >/dev/null 2>&1; then
    run bash "$CAST_OLLAMA_SH" status
    assert_failure
    assert_output --partial "not installed"
  else
    run bash "$CAST_OLLAMA_SH" status
    # May succeed or fail depending on whether ollama serve is running
    assert_output --partial "Ollama"
  fi
}

@test "cast-ollama.sh: query fails gracefully when Ollama not running" {
  # Point to a non-existent host
  export OLLAMA_HOST="http://localhost:99999"
  run bash "$CAST_OLLAMA_SH" query "hello"
  assert_failure
  assert_output --partial "not running"
}

@test "cast-ollama.sh: pull requires Ollama to be installed" {
  if ! command -v ollama >/dev/null 2>&1; then
    run bash "$CAST_OLLAMA_SH" pull
    assert_failure
    assert_output --partial "not installed"
  else
    # If installed but not running, should fail gracefully
    export OLLAMA_HOST="http://localhost:99999"
    run bash "$CAST_OLLAMA_SH" pull
    assert_failure
  fi
}
