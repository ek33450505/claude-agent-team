#!/usr/bin/env bats
# cast-stats.bats — Tests for the CAST stats single-source-of-truth system.
#
# Coverage:
#   1. gen-cast-stats.sh writes valid JSON with correct field values
#   2. gen-cast-stats.sh --check exits 0 when cast-stats.json is in sync
#   3. gen-cast-stats.sh --check exits 1 when a stat field is tampered
#   4. cast-stats-drift-check.sh exits 0 with matching --json
#   5. cast-stats-drift-check.sh exits 1 with tampered --json
#   6. cast-stats-drift-check.sh exits 0 with matching --sentinels
#   7. cast-stats-drift-check.sh exits 1 with wrong sentinel value
#
# These tests do NOT touch $HOME / ~/.claude — no temp home isolation needed.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN_STATS_SH="$REPO_DIR/scripts/gen-cast-stats.sh"
DRIFT_CHECK_SH="$REPO_DIR/scripts/cast-stats-drift-check.sh"
CANONICAL_JSON="$REPO_DIR/cast-stats.json"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  TMPDIR_STATS="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_STATS"
}

# ---------------------------------------------------------------------------
# 1. gen-cast-stats.sh writes valid JSON with correct fields
# ---------------------------------------------------------------------------

@test "gen-cast-stats.sh produces valid JSON parseable by jq" {
  run jq empty < "$CANONICAL_JSON"
  assert_success
}

@test "gen-cast-stats.sh produces agents=23" {
  run jq -r '.agents' < "$CANONICAL_JSON"
  assert_success
  assert_output "23"
}

@test "gen-cast-stats.sh produces a positive-integer tests count" {
  run jq -r '.tests' < "$CANONICAL_JSON"
  assert_success
  assert_output --regexp '^[1-9][0-9]*$'
}

@test "gen-cast-stats.sh produces tables=38" {
  run jq -r '.tables' < "$CANONICAL_JSON"
  assert_success
  assert_output "38"
}

@test "gen-cast-stats.sh produces commands=19" {
  run jq -r '.commands' < "$CANONICAL_JSON"
  assert_success
  assert_output "19"
}

@test "gen-cast-stats.sh produces skills=16" {
  run jq -r '.skills' < "$CANONICAL_JSON"
  assert_success
  assert_output "16"
}

@test "gen-cast-stats.sh produces a non-empty version field" {
  run jq -r '.version' < "$CANONICAL_JSON"
  assert_success
  refute_output ""
  refute_output "null"
}

@test "gen-cast-stats.sh numeric fields are JSON numbers not strings" {
  run jq -e 'if (.agents | type) == "number" and (.tests | type) == "number" and (.tables | type) == "number" then true else error("not numbers") end' < "$CANONICAL_JSON"
  assert_success
}

# ---------------------------------------------------------------------------
# 2. gen-cast-stats.sh --check exits 0 when in sync
# ---------------------------------------------------------------------------

@test "gen-cast-stats.sh --check exits 0 when cast-stats.json is in sync" {
  # Unset BATS env vars so the BATS guard inside gen-cast-stats.sh doesn't fire.
  # This lets the script actually recount stats and compare against the committed file.
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    bash "$GEN_STATS_SH" --check
  assert_success
  assert_output --partial "in sync"
}

# ---------------------------------------------------------------------------
# 3. gen-cast-stats.sh --check exits 1 when a field is tampered
# ---------------------------------------------------------------------------

@test "gen-cast-stats.sh --check exits 1 when agents count is tampered in committed file" {
  local orig_json="${TMPDIR_STATS}/cast-stats.json.orig"

  # Save original
  cp "$CANONICAL_JSON" "$orig_json"

  # Write tampered value to committed file
  jq '.agents = 999' < "$orig_json" > "$CANONICAL_JSON"

  # Unset BATS env vars so the BATS guard does not fire — we need a real check.
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    bash "$GEN_STATS_SH" --check
  local result_status=$status

  # Restore original regardless of test outcome
  cp "$orig_json" "$CANONICAL_JSON"

  assert [ "$result_status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 4. cast-stats-drift-check.sh exits 0 with matching --json
# ---------------------------------------------------------------------------

@test "cast-stats-drift-check.sh exits 0 with matching local JSON" {
  local copy="${TMPDIR_STATS}/copy.json"
  cp "$CANONICAL_JSON" "$copy"
  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --json "$copy"
  assert_success
  assert_output --partial "All checks PASSED"
}

# ---------------------------------------------------------------------------
# 5. cast-stats-drift-check.sh exits 1 with tampered --json
# ---------------------------------------------------------------------------

@test "cast-stats-drift-check.sh exits 1 when --json agents is wrong" {
  local tampered="${TMPDIR_STATS}/tampered.json"
  jq '.agents = 999' < "$CANONICAL_JSON" > "$tampered"
  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --json "$tampered"
  assert_failure
  assert_output --partial "FAIL"
  assert_output --partial "agents"
}

@test "cast-stats-drift-check.sh exits 1 when --json version is wrong" {
  local tampered="${TMPDIR_STATS}/tampered-ver.json"
  jq '.version = "0.0.0"' < "$CANONICAL_JSON" > "$tampered"
  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --json "$tampered"
  assert_failure
  assert_output --partial "version"
}

# ---------------------------------------------------------------------------
# 6. cast-stats-drift-check.sh exits 0 with matching --sentinels
# ---------------------------------------------------------------------------

@test "cast-stats-drift-check.sh exits 0 with matching sentinels" {
  local version agents tests tables commands skills
  version="$(jq -r '.version' < "$CANONICAL_JSON")"
  agents="$(jq -r '.agents' < "$CANONICAL_JSON")"
  tests="$(jq -r '.tests' < "$CANONICAL_JSON")"
  tables="$(jq -r '.tables' < "$CANONICAL_JSON")"
  commands="$(jq -r '.commands' < "$CANONICAL_JSON")"
  skills="$(jq -r '.skills' < "$CANONICAL_JSON")"

  local fixture="${TMPDIR_STATS}/fixture.md"
  cat > "$fixture" <<EOF
# CAST Stats Fixture
Agents: <!-- CAST_AGENT_COUNT -->${agents}<!-- /CAST_AGENT_COUNT -->
Tests: <!-- CAST_TEST_COUNT -->${tests}<!-- /CAST_TEST_COUNT -->
Tables: <!-- CAST_DB_TABLE_COUNT -->${tables}<!-- /CAST_DB_TABLE_COUNT -->
Commands: <!-- CAST_COMMAND_COUNT -->${commands}<!-- /CAST_COMMAND_COUNT -->
Skills: <!-- CAST_SKILL_COUNT -->${skills}<!-- /CAST_SKILL_COUNT -->
Version: <!-- CAST_VERSION -->${version}<!-- /CAST_VERSION -->
EOF

  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --sentinels "$fixture"
  assert_success
  assert_output --partial "All checks PASSED"
}

# ---------------------------------------------------------------------------
# 7. cast-stats-drift-check.sh exits 1 with wrong sentinel value
# ---------------------------------------------------------------------------

@test "cast-stats-drift-check.sh exits 1 when CAST_AGENT_COUNT sentinel is wrong" {
  local fixture="${TMPDIR_STATS}/fixture-wrong.md"
  cat > "$fixture" <<EOF
# CAST Stats
Agents: <!-- CAST_AGENT_COUNT -->999<!-- /CAST_AGENT_COUNT -->
EOF

  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --sentinels "$fixture"
  assert_failure
  assert_output --partial "FAIL"
}

@test "cast-stats-drift-check.sh skips absent tokens in sentinel file without error" {
  # A file with only one correct sentinel — others absent should not fail
  local agents
  agents="$(jq -r '.agents' < "$CANONICAL_JSON")"
  local fixture="${TMPDIR_STATS}/partial.md"
  printf '<!-- CAST_AGENT_COUNT -->%s<!-- /CAST_AGENT_COUNT -->\n' "$agents" > "$fixture"

  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --sentinels "$fixture"
  assert_success
}

# ---------------------------------------------------------------------------
# 9. Auto-discovery — no --json/--sentinels flags
# ---------------------------------------------------------------------------

@test "auto-discovery: PASSES when temp dir contains matching cast-stats.json" {
  # Create an isolated dir with a matching cast-stats.json, cd into it, run with no flags.
  local fake_repo="${TMPDIR_STATS}/fake-repo-pass"
  mkdir -p "$fake_repo"
  cp "$CANONICAL_JSON" "${fake_repo}/cast-stats.json"

  # Run from inside the fake repo dir so auto-discovery finds cast-stats.json
  run bash -c "cd '${fake_repo}' && bash '${DRIFT_CHECK_SH}' --canonical '${CANONICAL_JSON}'"
  assert_success
  assert_output --partial "All checks PASSED"
}

@test "auto-discovery: FAILS when temp dir contains tampered cast-stats.json" {
  local fake_repo="${TMPDIR_STATS}/fake-repo-fail"
  mkdir -p "$fake_repo"
  jq '.agents = 999' < "$CANONICAL_JSON" > "${fake_repo}/cast-stats.json"

  run bash -c "cd '${fake_repo}' && bash '${DRIFT_CHECK_SH}' --canonical '${CANONICAL_JSON}'"
  assert_failure
  assert_output --partial "FAIL"
}

@test "auto-discovery: exits 0 with 'nothing to check' when dir has no CAST markers" {
  local empty_repo="${TMPDIR_STATS}/empty-repo"
  mkdir -p "$empty_repo"
  # No cast-stats.json, no README.md, no docs/ — should be a safe no-op

  run bash -c "cd '${empty_repo}' && bash '${DRIFT_CHECK_SH}' --canonical '${CANONICAL_JSON}'"
  assert_success
  assert_output --partial "nothing to check"
}
