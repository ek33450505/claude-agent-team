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
#   - All --remote invocations use a PATH-shimmed curl stub (offline, hermetic) — no real network

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

# ---------------------------------------------------------------------------
# Remote test helpers
# ---------------------------------------------------------------------------

# Create a PATH-shimmed curl stub and three fixture ecosystem docs.
# Sets: STUB_DIR, REMOTE_DOC_AB, REMOTE_DOC_A, REMOTE_DOC_UNRESOLVABLE
#
# Stub behaviour:
#   cast-remote-a  /VERSION         → "3.0.0", exit 0   (VERSION path)
#   cast-remote-b  /VERSION         → exit 22            (simulate HTTP 404 / -f fail)
#   cast-remote-b  /package.json    → {"version":"4.0.0"}, exit 0  (pkg fallback)
#   cast-remote-unresolvable / *    → exit 22            (fully unresolvable)
_init_remote_fixtures() {
  STUB_DIR="${FIXTURE_DIR}/stub-bin"
  mkdir -p "$STUB_DIR"
  cat > "${STUB_DIR}/curl" <<'STUB'
#!/usr/bin/env bash
# Hermetic curl stub — parses URL arg, returns fixture data, zero network calls.
url=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *)  url="$arg" ;;
  esac
done
slug="" ; file=""
if [[ "$url" =~ raw\.githubusercontent\.com/ek33450505/([^/]+)/HEAD/([^/]+) ]]; then
  slug="${BASH_REMATCH[1]}"
  file="${BASH_REMATCH[2]}"
fi
case "${slug}/${file}" in
  "cast-remote-a/VERSION")
    printf '3.0.0\n'; exit 0 ;;
  "cast-remote-b/VERSION")
    exit 22 ;;
  "cast-remote-b/package.json")
    printf '{"name":"cast-remote-b","version":"4.0.0"}\n'; exit 0 ;;
  "cast-remote-unresolvable/VERSION"|"cast-remote-unresolvable/package.json")
    exit 22 ;;
  *)
    exit 22 ;;
esac
STUB
  chmod +x "${STUB_DIR}/curl"

  # Two slugs: one VERSION-based, one package.json-based
  REMOTE_DOC_AB="${FIXTURE_DIR}/remote-ecosystem-ab.md"
  cat > "$REMOTE_DOC_AB" <<'EOF'
# CAST Ecosystem (remote fixture)

<!-- ECOSYSTEM_START -->
| [cast-remote-a](https://github.com/ek33450505/cast-remote-a) | VERSION-based |
| [cast-remote-b](https://github.com/ek33450505/cast-remote-b) | package.json fallback |
<!-- ECOSYSTEM_END -->
EOF

  # Single slug: VERSION-based only (for --check tests)
  REMOTE_DOC_A="${FIXTURE_DIR}/remote-ecosystem-a.md"
  cat > "$REMOTE_DOC_A" <<'EOF'
# CAST Ecosystem (remote fixture, single slug)

<!-- ECOSYSTEM_START -->
| [cast-remote-a](https://github.com/ek33450505/cast-remote-a) | VERSION-based |
<!-- ECOSYSTEM_END -->
EOF

  # Single slug: fully unresolvable (for committed-fallback test)
  REMOTE_DOC_UNRESOLVABLE="${FIXTURE_DIR}/remote-ecosystem-unresolvable.md"
  cat > "$REMOTE_DOC_UNRESOLVABLE" <<'EOF'
# CAST Ecosystem (unresolvable fixture)

<!-- ECOSYSTEM_START -->
| [cast-remote-unresolvable](https://github.com/ek33450505/cast-remote-unresolvable) | always fails |
<!-- ECOSYSTEM_END -->
EOF
}

# Run the script in --remote mode with the PATH-shimmed curl stub.
# Requires _init_remote_fixtures to have been called in the same test.
# Usage: _run_remote <doc_path> [extra_script_flags...]
_run_remote() {
  local doc="$1"; shift
  run env \
    PATH="${STUB_DIR}:${PATH}" \
    CAST_ECOSYSTEM_DOC="$doc" \
    CAST_ECOSYSTEM_ROOT="$FIXTURE_REPOS" \
    CAST_ECOSYSTEM_VERSIONS_OUT="$FIXTURE_OUT" \
    bash "$SCRIPT" --remote "$@"
}

# ---------------------------------------------------------------------------
# (h) --remote write mode: VERSION path resolved via curl stub
# ---------------------------------------------------------------------------

@test "--remote: resolves cast-remote-a via VERSION stub and writes correct version" {
  _init_remote_fixtures
  _run_remote "$REMOTE_DOC_AB"
  assert_success
  run jq -r '."cast-remote-a"' < "$FIXTURE_OUT"
  assert_output "3.0.0"
}

@test "--remote: output JSON has _generator field (write mode)" {
  _init_remote_fixtures
  _run_remote "$REMOTE_DOC_AB"
  assert_success
  run jq -r '."_generator"' < "$FIXTURE_OUT"
  assert_output "scripts/gen-ecosystem-versions.sh"
}

# ---------------------------------------------------------------------------
# (i) --remote: package.json fallback (VERSION stub exits 22, pkg stub succeeds)
# ---------------------------------------------------------------------------

@test "--remote: resolves cast-remote-b via package.json when VERSION returns 404 (exit 22)" {
  _init_remote_fixtures
  _run_remote "$REMOTE_DOC_AB"
  assert_success
  run jq -r '."cast-remote-b"' < "$FIXTURE_OUT"
  assert_output "4.0.0"
}

# ---------------------------------------------------------------------------
# (j) --remote --check: exits 0 when in sync, exits 1 on drift
# ---------------------------------------------------------------------------

@test "--remote --check: exits 0 when stub-resolved versions match committed output" {
  _init_remote_fixtures
  # Write first so committed output holds the stub-resolved version
  _run_remote "$REMOTE_DOC_A"
  assert_success

  # --check re-resolves via stub (3.0.0) and compares to committed (3.0.0) → in sync
  _run_remote "$REMOTE_DOC_A" --check
  assert_success
  assert_output --partial "in sync"
}

@test "--remote --check: exits 1 (DRIFT) when committed output differs from stub-resolved version" {
  _init_remote_fixtures
  # Pre-seed committed file with wrong version for cast-remote-a
  printf '{"_generator":"scripts/gen-ecosystem-versions.sh","cast-remote-a":"9.9.9"}\n' \
    > "$FIXTURE_OUT"

  # Stub resolves 3.0.0; committed says 9.9.9 → drift detected
  _run_remote "$REMOTE_DOC_A" --check
  assert_failure
  assert_output --partial "DRIFT"
}

# ---------------------------------------------------------------------------
# (k) Committed-fallback SUCCESS: unresolvable slug reuses committed value
# ---------------------------------------------------------------------------

@test "--remote: unresolvable slug falls back to committed value without failing" {
  _init_remote_fixtures
  # Pre-seed committed file with the last-known version for the unresolvable slug
  printf '{"_generator":"scripts/gen-ecosystem-versions.sh","cast-remote-unresolvable":"0.1.0"}\n' \
    > "$FIXTURE_OUT"

  # Stub returns exit 22 for both VERSION and package.json on this slug;
  # script must fall back to the committed value ("0.1.0") and exit 0
  _run_remote "$REMOTE_DOC_UNRESOLVABLE"
  assert_success
  run jq -r '."cast-remote-unresolvable"' < "$FIXTURE_OUT"
  assert_output "0.1.0"
}
