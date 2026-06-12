#!/usr/bin/env bats
# cast-lint-agent-roster.bats — BATS tests for cast-lint-agent-roster.py
#
# All tests use an isolated temp HOME and fixture files so they never consult
# the live ~/.claude or modify the real repo.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_PY="$REPO_DIR/scripts/cast-lint-agent-roster.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  FIXTURE_DIR="$(mktemp -d)"
  FIXTURE_AGENTS="${FIXTURE_DIR}/agents"
  FIXTURE_ROSTER="${FIXTURE_DIR}/AGENT-ROSTER.md"
  mkdir -p "${FIXTURE_AGENTS}"
}

teardown() {
  rm -rf "${FIXTURE_DIR}"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_roster() {
  # $@ = lines to add to the table body (each: "name model")
  local outfile="${FIXTURE_ROSTER}"
  printf '# CAST Agent Roster\n\n' > "${outfile}"
  printf '| Agent | Model | Purpose |\n' >> "${outfile}"
  printf '|---|---|---|\n' >> "${outfile}"
  for spec in "$@"; do
    local name model
    name="${spec%% *}"
    model="${spec##* }"
    printf '| `%s` | %s | some purpose |\n' "${name}" "${model}" >> "${outfile}"
  done
}

_write_def() {
  local name="$1" model="$2"
  printf -- '---\nname: %s\nmodel: %s\n---\n\nAgent body.\n' \
    "${name}" "${model}" > "${FIXTURE_AGENTS}/${name}.md"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "pass on the real repo (roster and defs currently in sync)" {
  run python3 "${LINT_PY}"
  assert_success
}

@test "pass when fixture roster and defs match exactly" {
  _write_roster "alpha sonnet" "beta haiku"
  _write_def "alpha" "sonnet"
  _write_def "beta" "haiku"
  run env CAST_ROSTER_FILE="${FIXTURE_ROSTER}" \
         CAST_AGENTS_DIR="${FIXTURE_AGENTS}" \
         python3 "${LINT_PY}"
  assert_success
}

@test "fail when roster row has no def file" {
  _write_roster "orphan-agent sonnet"
  # no def written for orphan-agent
  run env CAST_ROSTER_FILE="${FIXTURE_ROSTER}" \
         CAST_AGENTS_DIR="${FIXTURE_AGENTS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "roster-only"
  assert_output --partial "orphan-agent"
}

@test "fail when def file is not in roster" {
  _write_roster "known-agent haiku"
  _write_def "known-agent" "haiku"
  _write_def "unlisted-agent" "sonnet"  # extra def not in roster
  run env CAST_ROSTER_FILE="${FIXTURE_ROSTER}" \
         CAST_AGENTS_DIR="${FIXTURE_AGENTS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "def-only"
  assert_output --partial "unlisted-agent"
}

@test "fail when roster model does not match def frontmatter model" {
  _write_roster "myagent haiku"
  _write_def "myagent" "sonnet"  # def says sonnet, roster says haiku
  run env CAST_ROSTER_FILE="${FIXTURE_ROSTER}" \
         CAST_AGENTS_DIR="${FIXTURE_AGENTS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "model mismatch"
  assert_output --partial "myagent"
  assert_output --partial "haiku"
  assert_output --partial "sonnet"
}

@test "pass when same-name, same-model agent exists in both surfaces" {
  _write_roster "good-agent opus"
  _write_def "good-agent" "opus"
  run env CAST_ROSTER_FILE="${FIXTURE_ROSTER}" \
         CAST_AGENTS_DIR="${FIXTURE_AGENTS}" \
         python3 "${LINT_PY}"
  assert_success
}

@test "fail when roster file is missing" {
  run env CAST_ROSTER_FILE="${FIXTURE_DIR}/does-not-exist.md" \
         CAST_AGENTS_DIR="${FIXTURE_AGENTS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "not found"
}

@test "fail when agents dir is missing" {
  _write_roster "a sonnet"
  run env CAST_ROSTER_FILE="${FIXTURE_ROSTER}" \
         CAST_AGENTS_DIR="${FIXTURE_DIR}/nonexistent-agents" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "not found"
}

@test "fail listing all discrepancy types when multiple issues exist" {
  _write_roster "only-in-roster haiku"
  _write_def "only-in-def" "sonnet"
  run env CAST_ROSTER_FILE="${FIXTURE_ROSTER}" \
         CAST_AGENTS_DIR="${FIXTURE_AGENTS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "roster-only"
  assert_output --partial "def-only"
}
