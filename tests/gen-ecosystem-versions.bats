#!/usr/bin/env bats
# gen-ecosystem-versions.bats — Tests for scripts/gen-ecosystem-versions.sh
#
# Coverage:
#   (a) Write mode: emits valid JSON with fixture keys, correct values, and _generator
#   (b) --check exits 0 when ecosystem-versions.json is in sync
#   (c) --check exits 1 after a fixture VERSION file is modified (drift detected)
#   (d) Plausibility floor: non-semver VERSION causes exit 1 in write mode
#   (e) package.json fallback: resolves version when VERSION file absent
#   (f) Missing ecosystem doc: exits 1 with error
#   (g) --check exits 1 when output file is missing
#
# Isolation:
#   - setup_temp_home / teardown_temp_home isolate $HOME (no real ~/.claude touched)
#   - CAST_ECOSYSTEM_DOC, CAST_ECOSYSTEM_ROOT, CAST_ECOSYSTEM_VERSIONS_OUT all
#     point into per-test mktemp dirs — the real ecosystem-versions.json is never read
#     or written
#   - No --remote flag is ever invoked (offline, hermetic)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/gen-ecosystem-versions.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  FIXTURE_DIR="$(mktemp -d)"

  # Fixture ecosystem.md with two repos: one uses VERSION, one uses package.json
  FIXTURE_DOC="${FIXTURE_DIR}/ecosystem.md"
  cat > "$FIXTURE_DOC" <<'EOF'
# CAST Ecosystem (fixture)

<!-- ECOSYSTEM_START -->
| [cast-fixture-a](https://github.com/ek33450505/cast-fixture-a) | VERSION-based repo |
| [cast-fixture-b](https://github.com/ek33450505/cast-fixture-b) | package.json-based repo |
<!-- ECOSYSTEM_END -->

Other content not in block.
EOF

  # Fixture repo tree
  FIXTURE_REPOS="${FIXTURE_DIR}/repos"
  mkdir -p "${FIXTURE_REPOS}/cast-fixture-a"
  mkdir -p "${FIXTURE_REPOS}/cast-fixture-b"

  # cast-fixture-a: VERSION file
  printf '1.2.3\n' > "${FIXTURE_REPOS}/cast-fixture-a/VERSION"

  # cast-fixture-b: package.json (no VERSION — exercises fallback path)
  printf '{"name":"cast-fixture-b","version":"2.0.0"}\n' \
    > "${FIXTURE_REPOS}/cast-fixture-b/package.json"

  # Output file path (does not exist initially)
  FIXTURE_OUT="${FIXTURE_DIR}/ecosystem-versions.json"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
  teardown_temp_home
}

# Helper: run script with all fixture env vars wired
_run_script() {
  run env \
    CAST_ECOSYSTEM_DOC="$FIXTURE_DOC" \
    CAST_ECOSYSTEM_ROOT="$FIXTURE_REPOS" \
    CAST_ECOSYSTEM_VERSIONS_OUT="$FIXTURE_OUT" \
    bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# (a) Write mode: valid JSON with expected keys/values + _generator
# ---------------------------------------------------------------------------

@test "write mode: exits 0 and creates output file" {
  _run_script
  assert_success
  [[ -f "$FIXTURE_OUT" ]]
}

@test "write mode: output is valid JSON (jq-parseable)" {
  _run_script
  assert_success
  run jq empty < "$FIXTURE_OUT"
  assert_success
}

@test "write mode: cast-fixture-a version resolves from VERSION file" {
  _run_script
  assert_success
  run jq -r '."cast-fixture-a"' < "$FIXTURE_OUT"
  assert_success
  assert_output "1.2.3"
}

@test "write mode: cast-fixture-b version resolves from package.json (fallback path)" {
  _run_script
  assert_success
  run jq -r '."cast-fixture-b"' < "$FIXTURE_OUT"
  assert_success
  assert_output "2.0.0"
}

@test "write mode: _generator field is present and correct" {
  _run_script
  assert_success
  run jq -r '."_generator"' < "$FIXTURE_OUT"
  assert_success
  assert_output "scripts/gen-ecosystem-versions.sh"
}

@test "write mode: output has no _date or timestamp field (deterministic)" {
  _run_script
  assert_success
  run jq -r '.date // "absent"' < "$FIXTURE_OUT"
  assert_output "absent"
  run jq -r '.updated // "absent"' < "$FIXTURE_OUT"
  assert_output "absent"
  run jq -r '.timestamp // "absent"' < "$FIXTURE_OUT"
  assert_output "absent"
}

@test "write mode: output keys are sorted (_generator first, then cast-*)" {
  _run_script
  assert_success
  # First key in sorted object should be _generator (underscore < letters)
  run jq -r 'keys[0]' < "$FIXTURE_OUT"
  assert_output "_generator"
}

# ---------------------------------------------------------------------------
# (b) --check exits 0 when in sync
# ---------------------------------------------------------------------------

@test "--check exits 0 when ecosystem-versions.json is in sync" {
  # Write first
  _run_script
  assert_success

  # Check
  _run_script --check
  assert_success
  assert_output --partial "in sync"
}

# ---------------------------------------------------------------------------
# (c) --check exits 1 after fixture VERSION is changed (drift)
# ---------------------------------------------------------------------------

@test "--check exits 1 after VERSION file is modified" {
  # Write initial file
  _run_script
  assert_success

  # Bump the VERSION so local source no longer matches committed
  printf '9.9.9\n' > "${FIXTURE_REPOS}/cast-fixture-a/VERSION"

  # Check should detect drift
  _run_script --check
  assert_failure
  assert_output --partial "DRIFT"
}

@test "--check prints diff output to stderr on drift" {
  _run_script
  assert_success

  printf '9.9.9\n' > "${FIXTURE_REPOS}/cast-fixture-a/VERSION"

  _run_script --check
  assert_failure
  # The diff block appears in combined stderr/stdout via run
  assert_output --partial "cast-fixture-a"
}

# ---------------------------------------------------------------------------
# (d) Plausibility floor: non-semver VERSION causes exit 1
# ---------------------------------------------------------------------------

@test "plausibility floor: non-semver VERSION exits 1" {
  printf 'not-a-version\n' > "${FIXTURE_REPOS}/cast-fixture-a/VERSION"
  _run_script
  assert_failure
  assert_output --partial "Implausible version"
}

@test "plausibility floor: empty VERSION exits 1 (no committed fallback)" {
  printf '\n' > "${FIXTURE_REPOS}/cast-fixture-a/VERSION"
  _run_script
  assert_failure
}

@test "plausibility floor: version 'v1.2.3' (prefixed) exits 1" {
  printf 'v1.2.3\n' > "${FIXTURE_REPOS}/cast-fixture-a/VERSION"
  _run_script
  assert_failure
  assert_output --partial "Implausible version"
}

# ---------------------------------------------------------------------------
# (e) package.json fallback is not used when VERSION exists
# ---------------------------------------------------------------------------

@test "package.json is ignored when VERSION file is present" {
  # Add a package.json with a different version to cast-fixture-a
  printf '{"name":"cast-fixture-a","version":"9.9.9"}\n' \
    > "${FIXTURE_REPOS}/cast-fixture-a/package.json"

  # Version should still come from VERSION file (1.2.3), not package.json (9.9.9)
  _run_script
  assert_success
  run jq -r '."cast-fixture-a"' < "$FIXTURE_OUT"
  assert_output "1.2.3"
}

# ---------------------------------------------------------------------------
# (f) Missing ecosystem doc: exits 1
# ---------------------------------------------------------------------------

@test "missing ecosystem doc exits 1 with error message" {
  run env \
    CAST_ECOSYSTEM_DOC="${FIXTURE_DIR}/nonexistent-ecosystem.md" \
    CAST_ECOSYSTEM_ROOT="$FIXTURE_REPOS" \
    CAST_ECOSYSTEM_VERSIONS_OUT="$FIXTURE_OUT" \
    bash "$SCRIPT"
  assert_failure
  assert_output --partial "ERROR"
}

# ---------------------------------------------------------------------------
# (g) --check exits 1 when output file is missing
# ---------------------------------------------------------------------------

@test "--check exits 1 when output file does not exist" {
  # Do NOT write first — output file absent
  _run_script --check
  assert_failure
  assert_output --partial "not found"
}
