#!/usr/bin/env bats

# cast-neon.bats — Tests for cast-neon.sh (fail-closed Neon write wrapper, CAST v10 I-5 Unit B)
#
# Coverage:
#   - --help / no-args usage
#   - missing API key -> exit 1, key never in output, curl never invoked
#   - auth via $NEON_API_KEY and via cast-keychain.sh fallback (Keychain-dependent
#     tests are macOS-only, matching cast-keychain.sh's own platform requirement).
#     The key travels to curl via stdin (-K -), never argv — asserted directly.
#   - list-projects / list-branches / branch-create: no escape hatch needed
#   - branch-create JSON body is built via python3 json.dumps (argv-passed value,
#     never interpolated into program text) — a branch name containing a double
#     quote must not break out of the JSON string or inject sibling keys
#   - project_id / branch_id charset validation (^[A-Za-z0-9_-]+$) rejects an
#     embedded "/" before it ever reaches curl
#   - branch-delete gate: unset / "0" / "true" / "10" all BLOCK (literal-"1" only)
#     on a REAL run; "1" proceeds. --dry-run is exempt from the gate entirely.
#   - --dry-run: no curl call, for both a non-destructive and the destructive command
#
# Isolated temp HOME (required by project convention). Stubs curl (records argv
# AND stdin to separate files) and security (the macOS Keychain CLI cast-keychain.sh
# shells out to) so there are zero real network calls and zero dependence on the
# host's real Keychain state (load-bearing: this machine may have a REAL
# cast-neon-api-key entry stored for actual use of this tool).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_NEON_SH="$REPO_DIR/scripts/cast-neon.sh"

setup() {
  setup_temp_home

  STUB_DIR="$(mktemp -d)"
  export PATH="$STUB_DIR:$PATH"

  local stub_state_dir
  stub_state_dir="$(mktemp -d)"
  CURL_ARGV_FILE="$stub_state_dir/curl-argv"
  CURL_STDIN_FILE="$stub_state_dir/curl-stdin"
  export CURL_ARGV_FILE CURL_STDIN_FILE
  rm -f "$CURL_ARGV_FILE" "$CURL_STDIN_FILE"

  cat > "$STUB_DIR/curl" <<'CURLSTUB'
#!/bin/bash
echo "$@" >> "$CURL_ARGV_FILE"
cat > "$CURL_STDIN_FILE" 2>/dev/null
echo '{"stub":"ok"}'
exit 0
CURLSTUB
  chmod +x "$STUB_DIR/curl"

  # Default: no Keychain entry found (fail closed). Individual tests override
  # this to simulate a stored key. Intercepts the `security` binary that
  # cast-keychain.sh shells out to, so the real host Keychain is never touched.
  cat > "$STUB_DIR/security" <<'SECSTUB'
#!/bin/bash
exit 1
SECSTUB
  chmod +x "$STUB_DIR/security"

  unset NEON_API_KEY CAST_NEON_BRANCH_DELETE_OK || true
}

teardown() {
  [[ -d "$STUB_DIR" ]] && rm -rf "$STUB_DIR"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------

@test "--help prints usage and mentions the branch-delete gate" {
  run bash "$CAST_NEON_SH" --help
  assert_success
  assert_output --partial "branch-delete"
  assert_output --partial "CAST_NEON_BRANCH_DELETE_OK"
}

@test "no args prints usage and exits 1" {
  run bash "$CAST_NEON_SH"
  assert_failure
  assert_output --partial "Usage"
}

@test "unknown command exits 1" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" bogus-command
  assert_failure
  assert_output --partial "unknown command"
}

# ---------------------------------------------------------------------------
# Auth resolution (fail-closed; key travels via stdin, never argv)
# ---------------------------------------------------------------------------

@test "missing API key -> exit 1, key never in output, curl never invoked" {
  run bash "$CAST_NEON_SH" list-projects
  assert_failure
  assert_output --partial "no Neon API key found"
  refute_output --partial "NEON_API_KEY="
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "auth via NEON_API_KEY succeeds, key goes to curl via stdin not argv" {
  NEON_API_KEY="super-secret-test-key" run bash "$CAST_NEON_SH" list-projects
  assert_success
  refute_output --partial "super-secret-test-key"

  run cat "$CURL_ARGV_FILE"
  assert_output --partial "GET"
  assert_output --partial "/projects"
  refute_output --partial "super-secret-test-key"

  run cat "$CURL_STDIN_FILE"
  assert_output --partial "Authorization: Bearer super-secret-test-key"
}

@test "auth falls back to Keychain when NEON_API_KEY unset" {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "cast-keychain.sh requires macOS"
  fi
  cat > "$STUB_DIR/security" <<'SECSTUB'
#!/bin/bash
if [[ "$1" == "find-generic-password" ]]; then
  echo "stub-keychain-neon-key"
  exit 0
fi
exit 1
SECSTUB
  chmod +x "$STUB_DIR/security"

  run bash "$CAST_NEON_SH" list-projects
  assert_success
  run cat "$CURL_ARGV_FILE"
  refute_output --partial "stub-keychain-neon-key"
  run cat "$CURL_STDIN_FILE"
  assert_output --partial "Authorization: Bearer stub-keychain-neon-key"
}

# ---------------------------------------------------------------------------
# Non-destructive commands need no escape hatch
# ---------------------------------------------------------------------------

@test "list-branches requires a project_id" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" list-branches
  assert_failure
  assert_output --partial "list-branches requires"
}

@test "list-branches succeeds with no hatch set" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" list-branches proj-123
  assert_success
  run cat "$CURL_ARGV_FILE"
  assert_output --partial "GET"
  assert_output --partial "/projects/proj-123/branches"
}

@test "branch-create succeeds with no hatch set" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" branch-create proj-123 feature-branch
  assert_success
  run cat "$CURL_ARGV_FILE"
  assert_output --partial "POST"
  assert_output --partial "/projects/proj-123/branches"
  assert_output --partial "feature-branch"
}

@test "branch-create JSON-escapes a double-quote in the branch name (no injection)" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" branch-create proj-123 'evil"branch'
  assert_success
  run cat "$CURL_ARGV_FILE"
  # json.dumps escapes the quote — the raw body must never contain an
  # unescaped `"branch"` that would close the JSON string early.
  assert_output --partial 'evil\"branch'
  refute_output --partial 'parent_id'
}

# ---------------------------------------------------------------------------
# project_id / branch_id charset validation
# ---------------------------------------------------------------------------

@test "list-branches rejects a project_id containing a slash" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" list-branches "proj-123/../other"
  assert_failure
  assert_output --partial "invalid project_id"
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "branch-delete rejects a project_id containing a slash" {
  NEON_API_KEY="test-key" CAST_NEON_BRANCH_DELETE_OK="1" run bash "$CAST_NEON_SH" branch-delete "proj/123" br-456
  assert_failure
  assert_output --partial "invalid project_id"
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "branch-delete rejects a branch_id containing a slash" {
  NEON_API_KEY="test-key" CAST_NEON_BRANCH_DELETE_OK="1" run bash "$CAST_NEON_SH" branch-delete proj-123 "br/456"
  assert_failure
  assert_output --partial "invalid branch_id"
  [ ! -e "$CURL_ARGV_FILE" ]
}

# ---------------------------------------------------------------------------
# branch-delete gate (real runs): literal "1" only
# ---------------------------------------------------------------------------

@test "branch-delete BLOCKS when hatch is unset (curl never invoked)" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" branch-delete proj-123 br-456
  assert_failure
  assert_output --partial "CAST_NEON_BRANCH_DELETE_OK"
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "branch-delete BLOCKS when hatch is 0" {
  NEON_API_KEY="test-key" CAST_NEON_BRANCH_DELETE_OK="0" run bash "$CAST_NEON_SH" branch-delete proj-123 br-456
  assert_failure
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "branch-delete BLOCKS when hatch is true" {
  NEON_API_KEY="test-key" CAST_NEON_BRANCH_DELETE_OK="true" run bash "$CAST_NEON_SH" branch-delete proj-123 br-456
  assert_failure
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "branch-delete BLOCKS when hatch is 10 (literal-1 property)" {
  NEON_API_KEY="test-key" CAST_NEON_BRANCH_DELETE_OK="10" run bash "$CAST_NEON_SH" branch-delete proj-123 br-456
  assert_failure
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "branch-delete proceeds when hatch is literal 1" {
  NEON_API_KEY="test-key" CAST_NEON_BRANCH_DELETE_OK="1" run bash "$CAST_NEON_SH" branch-delete proj-123 br-456
  assert_success
  run cat "$CURL_ARGV_FILE"
  assert_output --partial "DELETE"
  assert_output --partial "/projects/proj-123/branches/br-456"
}

# ---------------------------------------------------------------------------
# --dry-run: never touches curl. branch-delete's --dry-run is exempt from the
# hatch entirely (reversed by design decision from the security review).
# ---------------------------------------------------------------------------

@test "--dry-run on a non-destructive command makes no curl call" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" --dry-run list-projects
  assert_success
  assert_output --partial "[dry-run]"
  assert_output --partial "REDACTED"
  refute_output --partial "test-key"
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "--dry-run on branch-delete succeeds WITHOUT the hatch and makes no curl call" {
  NEON_API_KEY="test-key" run bash "$CAST_NEON_SH" --dry-run branch-delete proj-123 br-456
  assert_success
  assert_output --partial "[dry-run]"
  assert_output --partial "DELETE"
  [ ! -e "$CURL_ARGV_FILE" ]
}

@test "--dry-run on branch-delete with hatch set also succeeds and makes no curl call" {
  NEON_API_KEY="test-key" CAST_NEON_BRANCH_DELETE_OK="1" run bash "$CAST_NEON_SH" --dry-run branch-delete proj-123 br-456
  assert_success
  assert_output --partial "[dry-run]"
  assert_output --partial "DELETE"
  [ ! -e "$CURL_ARGV_FILE" ]
}
