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

@test "gen-cast-stats.sh produces agents=27" {
  run jq -r '.agents' < "$CANONICAL_JSON"
  assert_success
  assert_output "27"
}

@test "gen-cast-stats.sh produces a positive-integer tests count" {
  run jq -r '.tests' < "$CANONICAL_JSON"
  assert_success
  assert_output --regexp '^[1-9][0-9]*$'
}

@test "gen-cast-stats.sh produces tables=39" {
  run jq -r '.tables' < "$CANONICAL_JSON"
  assert_success
  assert_output "39"
}

@test "gen-cast-stats.sh produces commands=21" {
  run jq -r '.commands' < "$CANONICAL_JSON"
  assert_success
  assert_output "21"
}

@test "gen-cast-stats.sh produces skills=18" {
  run jq -r '.skills' < "$CANONICAL_JSON"
  assert_success
  assert_output "18"
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
# test_files field — new key added M1-B convergence
# ---------------------------------------------------------------------------

@test "gen-cast-stats.sh: test_files is a JSON number in cast-stats.json" {
  run jq -e 'if (.test_files | type) == "number" then true else error("test_files not a number") end' < "$CANONICAL_JSON"
  assert_success
}

@test "gen-cast-stats.sh: test_files is a positive integer" {
  run jq -r '.test_files' < "$CANONICAL_JSON"
  assert_success
  assert_output --regexp '^[1-9][0-9]*$'
}

@test "gen-cast-stats.sh: test_files matches cast_stat_test_files output" {
  # Load the lib and compare canonical JSON value against the live function output.
  # Both run from the same repo root so they should agree.
  source "$REPO_DIR/scripts/cast-stats-lib.sh"
  local live_count
  live_count="$(cast_stat_test_files)"
  local json_count
  json_count="$(jq -r '.test_files' < "$CANONICAL_JSON")"
  assert [ "$live_count" = "$json_count" ]
}

@test "cast_stats_assert_floors: test_files below floor returns 1 and emits FLOOR VIOLATION" {
  source "$REPO_DIR/scripts/cast-stats-lib.sh"
  # Pass valid values for positions 1-7 but test_files=100 (below 170 floor)
  run cast_stats_assert_floors 22 1258 39 20 15 9 9.0.0 100
  assert_failure
  assert_output --partial "FLOOR VIOLATION"
  assert_output --partial "test_files"
}

@test "cast_stats_assert_floors: omitting test_files arg still passes for valid stats" {
  source "$REPO_DIR/scripts/cast-stats-lib.sh"
  # 7-arg call (original signature) must still succeed — backward-compat
  run cast_stats_assert_floors 22 1258 39 20 15 9 9.0.0
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

# ---------------------------------------------------------------------------
# Floor unit tests — cast_stats_assert_floors (direct lib tests)
# ---------------------------------------------------------------------------

@test "cast_stats_assert_floors: valid stats return 0" {
  source "$REPO_DIR/scripts/cast-stats-lib.sh"
  run cast_stats_assert_floors 22 1258 39 20 15 13 7.4.1
  assert_success
}

@test "cast_stats_assert_floors: tables=0 returns 1 and stderr contains FLOOR VIOLATION" {
  source "$REPO_DIR/scripts/cast-stats-lib.sh"
  run cast_stats_assert_floors 22 1258 0 20 15 13 7.4.1
  assert_failure
  assert_output --partial "FLOOR VIOLATION"
}

@test "cast_stats_assert_floors: empty version returns 1 and stderr contains FLOOR VIOLATION" {
  source "$REPO_DIR/scripts/cast-stats-lib.sh"
  run cast_stats_assert_floors 22 1258 39 20 15 13 ""
  assert_failure
  assert_output --partial "FLOOR VIOLATION"
}

@test "floor fires in write mode when CAST_PACKAGES_COUNT=0" {
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    CAST_PACKAGES_COUNT=0 bash "$GEN_STATS_SH"
  assert_failure
  assert_output --partial "FLOOR VIOLATION"
}

@test "floor fires in --check mode when CAST_PACKAGES_COUNT=0 (tautology-breaker)" {
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    CAST_PACKAGES_COUNT=0 bash "$GEN_STATS_SH" --check
  assert_failure
  assert_output --partial "FLOOR VIOLATION"
}

@test "cast_stat_test_files: returns a numeric value at or above floor of 150" {
  source "$REPO_DIR/scripts/cast-stats-lib.sh"
  run cast_stat_test_files
  assert_success
  assert_output --regexp '^[0-9]+$'
  [ "$output" -ge 150 ]
}

@test "auto-discovery: exits 0 with 'nothing to check' when dir has no CAST markers" {
  local empty_repo="${TMPDIR_STATS}/empty-repo"
  mkdir -p "$empty_repo"
  # No cast-stats.json, no README.md, no docs/ — should be a safe no-op

  run bash -c "cd '${empty_repo}' && bash '${DRIFT_CHECK_SH}' --canonical '${CANONICAL_JSON}'"
  assert_success
  assert_output --partial "nothing to check"
}

# ---------------------------------------------------------------------------
# C1 structural guard — retry flags present in script source
# ---------------------------------------------------------------------------

@test "drift-check: --retry flag is present in script source" {
  run grep -q -- '--retry' "$DRIFT_CHECK_SH"
  assert_success
}

# ---------------------------------------------------------------------------
# C2 --ignore: JSON field filtering
# ---------------------------------------------------------------------------

@test "--ignore tests: PASSES when only tests field drifts in JSON" {
  local tampered="${TMPDIR_STATS}/tampered-tests.json"
  jq '.tests = 99999' < "$CANONICAL_JSON" > "$tampered"
  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --json "$tampered" --ignore tests
  assert_success
  assert_output --partial "All checks PASSED"
}

@test "without --ignore: FAILS when tests field drifts in JSON (regression guard)" {
  local tampered="${TMPDIR_STATS}/tampered-tests-noignore.json"
  jq '.tests = 99999' < "$CANONICAL_JSON" > "$tampered"
  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --json "$tampered"
  assert_failure
  assert_output --partial "FAIL"
  assert_output --partial "tests"
}

@test "--ignore tests,packages: skips both drifting fields" {
  local tampered="${TMPDIR_STATS}/tampered-tests-pkgs.json"
  jq '.tests = 99999 | .packages = 99999' < "$CANONICAL_JSON" > "$tampered"
  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --json "$tampered" --ignore tests,packages
  assert_success
  assert_output --partial "All checks PASSED"
}

# ---------------------------------------------------------------------------
# C2 --ignore: sentinel token filtering
# ---------------------------------------------------------------------------

@test "--ignore tests: PASSES when CAST_TEST_COUNT sentinel drifts" {
  local tests
  tests="$(jq -r '.tests' < "$CANONICAL_JSON")"
  local fixture="${TMPDIR_STATS}/sentinel-tests-ignore.md"
  cat > "$fixture" <<EOF
Tests: <!-- CAST_TEST_COUNT -->99999<!-- /CAST_TEST_COUNT -->
EOF
  run bash "$DRIFT_CHECK_SH" --canonical "$CANONICAL_JSON" --sentinels "$fixture" --ignore tests
  assert_success
  assert_output --partial "All checks PASSED"
}

# ---------------------------------------------------------------------------
# C2 --ignore + auto-discovery: checks non-ignored fields
# ---------------------------------------------------------------------------

@test "--ignore tests + auto-discovery: still FAILs when agents drifts (other fields checked)" {
  local fake_repo="${TMPDIR_STATS}/fake-repo-ignore-agents"
  mkdir -p "$fake_repo"
  jq '.tests = 99999 | .agents = 99999' < "$CANONICAL_JSON" > "${fake_repo}/cast-stats.json"

  run bash -c "cd '${fake_repo}' && bash '${DRIFT_CHECK_SH}' --canonical '${CANONICAL_JSON}' --ignore tests"
  assert_failure
  assert_output --partial "FAIL"
  assert_output --partial "agents"
}
