#!/usr/bin/env bats
# cast-lint-byte-budget.bats — BATS tests for cast-lint-byte-budget.sh
#
# All tests use an isolated temp HOME and a fixture rules directory so they
# never read the live ~/.claude or modify the real repo.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_SH="$REPO_DIR/scripts/cast-lint-byte-budget.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  FIXTURE_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: create a fixture file of exactly N bytes
# ---------------------------------------------------------------------------
_make_file() {
  local path="$1"
  local bytes="$2"
  python3 -c "import sys; sys.stdout.write('x' * ${bytes})" > "${path}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "default budget is 36864 bytes (pins the shipped default, no override)" {
  # Below-default fixture: no CAST_RULES_BYTE_BUDGET override — exercises the
  # script's own default literal, not a test-supplied one.
  _make_file "${FIXTURE_DIR}/under.md" 36000
  run bash -c "env CAST_RULES_DIR='${FIXTURE_DIR}' bash '${LINT_SH}' 2>&1"
  assert_success
  assert_output --partial "OK [lint-byte-budget]:"
  assert_output --partial "36864 bytes"

  # Above-default fixture: same no-override invocation, now over the default.
  _make_file "${FIXTURE_DIR}/under.md" 37000
  run bash -c "env CAST_RULES_DIR='${FIXTURE_DIR}' bash '${LINT_SH}' 2>&1"
  assert_success
  assert_output --partial "ADVISORY [lint-byte-budget]:"
  assert_output --partial "over the 36864-byte soft target"
}

@test "pass when fixture dir is within budget" {
  _make_file "${FIXTURE_DIR}/a.md" 5000
  _make_file "${FIXTURE_DIR}/b.md" 5000
  run env CAST_RULES_DIR="${FIXTURE_DIR}" CAST_RULES_BYTE_BUDGET=20480 bash "${LINT_SH}"
  assert_success
  assert_output --partial "OK [lint-byte-budget]:"
}

@test "advisory when fixture dir exceeds budget soft target" {
  _make_file "${FIXTURE_DIR}/big.md" 8000
  _make_file "${FIXTURE_DIR}/also-big.md" 7000
  # Total = 15000 bytes; budget = 10000 → advisory (not blocked)
  run bash -c "env CAST_RULES_DIR='${FIXTURE_DIR}' CAST_RULES_BYTE_BUDGET=10000 bash '${LINT_SH}' 2>&1"
  assert_success
  assert_output --partial "ADVISORY [lint-byte-budget]:"
  assert_output --partial "15000 bytes"
}

@test "advisory output includes per-file sizes sorted desc" {
  _make_file "${FIXTURE_DIR}/small.md" 100
  _make_file "${FIXTURE_DIR}/large.md" 500
  run bash -c "env CAST_RULES_DIR='${FIXTURE_DIR}' CAST_RULES_BYTE_BUDGET=100 bash '${LINT_SH}' 2>&1"
  assert_success
  assert_output --partial "ADVISORY [lint-byte-budget]:"
  # large.md (500) must appear before small.md (100) in output
  run bash -c "env CAST_RULES_DIR='${FIXTURE_DIR}' CAST_RULES_BYTE_BUDGET=100 bash '${LINT_SH}' 2>&1 | grep -n 'large.md\|small.md'"
  large_line=$(echo "$output" | grep large.md | cut -d: -f1)
  small_line=$(echo "$output" | grep small.md | cut -d: -f1)
  [[ "${large_line}" -lt "${small_line}" ]]
}

@test "env override of budget threshold works" {
  _make_file "${FIXTURE_DIR}/a.md" 1000
  # Should pass with a high budget (OK message)
  run env CAST_RULES_DIR="${FIXTURE_DIR}" CAST_RULES_BYTE_BUDGET=99999 bash "${LINT_SH}"
  assert_success
  assert_output --partial "OK [lint-byte-budget]:"
  # Should emit advisory with a very low budget (but still exit 0)
  run bash -c "env CAST_RULES_DIR='${FIXTURE_DIR}' CAST_RULES_BYTE_BUDGET=1 bash '${LINT_SH}' 2>&1"
  assert_success
  assert_output --partial "ADVISORY [lint-byte-budget]:"
}

@test "includes .md.template files in byte count" {
  _make_file "${FIXTURE_DIR}/a.md" 500
  _make_file "${FIXTURE_DIR}/b.md.template" 600
  # Total = 1100; budget = 1000 → advisory (template counted)
  run bash -c "env CAST_RULES_DIR='${FIXTURE_DIR}' CAST_RULES_BYTE_BUDGET=1000 bash '${LINT_SH}' 2>&1"
  assert_success
  assert_output --partial "ADVISORY [lint-byte-budget]:"
}

@test "exit 1 when rules dir does not exist" {
  run env CAST_RULES_DIR="/tmp/totally-nonexistent-cast-rules-dir-$$" bash "${LINT_SH}"
  assert_failure
  assert_output --partial "ERROR [lint-byte-budget]:"
}

@test "pass and warn on empty directory (no .md files)" {
  # Empty fixture dir has no .md files — should exit 0 with a warning
  run env CAST_RULES_DIR="${FIXTURE_DIR}" bash "${LINT_SH}"
  assert_success
  assert_output --partial "WARNING [lint-byte-budget]:"
}
