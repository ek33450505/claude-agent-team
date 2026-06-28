#!/usr/bin/env bats
# Tests for scripts/cast-count-planned-tests.sh and the run.sh count gate logic.
#
# HARD RULE: never invoke tests/run.sh against the real tests/ directory.
# End-to-end gate tests use fixture .bats files in a temp dir only.
#
# NOTE: fixture files are created with printf, NOT shell heredocs.
# BATS preprocesses its own source file and transforms any "@test" lines it
# finds — including inside heredoc bodies — into bats_test_function form.
# printf arguments are shell strings and bypass that transformation.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_DIR/scripts/cast-count-planned-tests.sh"

setup() {
  FIXTURE_DIR="$(mktemp -d)"
  SUB_HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$FIXTURE_DIR" "$SUB_HOME"
}

# ---------------------------------------------------------------------------
# Helper: cast-count-planned-tests.sh
# ---------------------------------------------------------------------------

@test "helper: outputs 0 when called with no arguments" {
  run bash "$HELPER"
  assert_success
  assert_output "0"
}

@test "helper: counts @test lines in a single fixture file" {
  printf '@test "one" { true; }\n@test "two" { true; }\n' > "$FIXTURE_DIR/a.bats"
  run bash "$HELPER" "$FIXTURE_DIR/a.bats"
  assert_success
  assert_output "2"
}

@test "helper: sums @test lines across multiple fixture files" {
  printf '@test "a1" { true; }\n@test "a2" { true; }\n' > "$FIXTURE_DIR/a.bats"
  printf '@test "b1" { true; }\n' > "$FIXTURE_DIR/b.bats"
  run bash "$HELPER" "$FIXTURE_DIR/a.bats" "$FIXTURE_DIR/b.bats"
  assert_success
  assert_output "3"
}

@test "helper: skips unreadable file, counts readable ones only" {
  if [ "$(id -u)" -eq 0 ]; then skip "chmod 000 does not restrict root; unreadable-file scenario is untestable as root"; fi
  printf '@test "a1" { true; }\n' > "$FIXTURE_DIR/a.bats"
  printf '@test "b1" { true; }\n@test "b2" { true; }\n' > "$FIXTURE_DIR/b.bats"
  chmod 000 "$FIXTURE_DIR/b.bats"
  run bash "$HELPER" "$FIXTURE_DIR/a.bats" "$FIXTURE_DIR/b.bats"
  assert_success
  assert_output "1"
  chmod 644 "$FIXTURE_DIR/b.bats"
}

@test "helper: does not count commented-out @test lines" {
  printf '@test "real test" { true; }\n# @test "commented out" { true; }\n' > "$FIXTURE_DIR/a.bats"
  run bash "$HELPER" "$FIXTURE_DIR/a.bats"
  assert_success
  assert_output "1"
}

@test "helper: does not count indented @test lines" {
  printf '@test "real test" { true; }\n  @test "indented" { true; }\n' > "$FIXTURE_DIR/a.bats"
  run bash "$HELPER" "$FIXTURE_DIR/a.bats"
  assert_success
  assert_output "1"
}

@test "helper: returns 0 for file with no @test lines" {
  printf 'just some content without test markers\n' > "$FIXTURE_DIR/a.bats"
  run bash "$HELPER" "$FIXTURE_DIR/a.bats"
  assert_success
  assert_output "0"
}

@test "helper: outputs 0 for nonexistent file without failing" {
  run bash "$HELPER" "$FIXTURE_DIR/does-not-exist.bats"
  assert_success
  assert_output "0"
}

# ---------------------------------------------------------------------------
# Gate comparison logic (mirrors run.sh gate inline)
# ---------------------------------------------------------------------------

# Shared gate snippet used in the tests below.
_run_gate() {
  local planned="$1"
  local executed="$2"
  bash -c '
    PLANNED="$1"; EXECUTED="$2"
    if [[ "$EXECUTED" -ne "$PLANNED" ]]; then
      printf "[cast-count-gate] FAIL: planned=%s executed=%s\n" "$PLANNED" "$EXECUTED" >&2
      exit 1
    fi
    exit 0
  ' _ "$planned" "$executed"
}

@test "gate: succeeds when executed count equals planned" {
  run _run_gate 5 5
  assert_success
}

@test "gate: fails with exit 1 when executed is less than planned" {
  run _run_gate 4 3
  assert_failure
}

@test "gate: fails with exit 1 when executed is greater than planned" {
  run _run_gate 3 4
  assert_failure
}

@test "gate: stderr message names both counts on failure" {
  run _run_gate 4 3
  assert_failure
  assert_output --partial "planned=4"
  assert_output --partial "executed=3"
}

# ---------------------------------------------------------------------------
# End-to-end: real bats invocation on fixtures, gate detects dropped file
# ---------------------------------------------------------------------------

@test "end-to-end: gate detects when bats executes fewer tests than planned" {
  # Create 3 fixture files: planned total = 4 @tests
  printf '@test "f1a" { true; }\n@test "f1b" { true; }\n' > "$FIXTURE_DIR/f1.bats"
  printf '@test "f2a" { true; }\n' > "$FIXTURE_DIR/f2.bats"
  printf '@test "f3a" { true; }\n' > "$FIXTURE_DIR/f3.bats"

  # Planned: all 3 files (4 total @tests)
  PLANNED="$(bash "$HELPER" "$FIXTURE_DIR/f1.bats" "$FIXTURE_DIR/f2.bats" "$FIXTURE_DIR/f3.bats")"
  [[ "$PLANNED" -eq 4 ]]

  # Simulate f3 silently dropped: bats runs only f1 + f2 (3 tests)
  TAP_OUT="$(mktemp)"
  env HOME="$SUB_HOME" bats --tap \
    "$FIXTURE_DIR/f1.bats" "$FIXTURE_DIR/f2.bats" > "$TAP_OUT" 2>/dev/null || true

  # Parse executed from TAP plan line
  EXECUTED="$(grep -m1 "^1\.\." "$TAP_OUT" | sed 's/^1\.\.//' | tr -d '[:space:]' || true)"
  if [[ -z "$EXECUTED" ]]; then
    EXECUTED="$(grep -cE "^(ok|not ok) " "$TAP_OUT" 2>/dev/null || echo 0)"
  fi
  rm -f "$TAP_OUT"

  # Gate condition fires: executed (3) != planned (4)
  [[ "$EXECUTED" -eq 3 ]]
  [[ "$PLANNED" -ne "$EXECUTED" ]]
}

@test "end-to-end: gate does not fire when all planned files are executed" {
  printf '@test "g1a" { true; }\n' > "$FIXTURE_DIR/g1.bats"
  printf '@test "g2a" { true; }\n' > "$FIXTURE_DIR/g2.bats"

  PLANNED="$(bash "$HELPER" "$FIXTURE_DIR/g1.bats" "$FIXTURE_DIR/g2.bats")"
  [[ "$PLANNED" -eq 2 ]]

  TAP_OUT="$(mktemp)"
  env HOME="$SUB_HOME" bats --tap \
    "$FIXTURE_DIR/g1.bats" "$FIXTURE_DIR/g2.bats" > "$TAP_OUT" 2>/dev/null || true

  EXECUTED="$(grep -m1 "^1\.\." "$TAP_OUT" | sed 's/^1\.\.//' | tr -d '[:space:]' || true)"
  if [[ -z "$EXECUTED" ]]; then
    EXECUTED="$(grep -cE "^(ok|not ok) " "$TAP_OUT" 2>/dev/null || echo 0)"
  fi
  rm -f "$TAP_OUT"

  [[ "$EXECUTED" -eq 2 ]]
  [[ "$PLANNED" -eq "$EXECUTED" ]]
}
