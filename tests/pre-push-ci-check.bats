#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/pre-push-ci-check.sh"

# ---------------------------------------------------------------------------
# Helper: run the ci-check script inside a fresh tmp git repo.
# Commits a single file with the given content, then runs the script in
# standalone mode (no stdin push refs → diffs HEAD~1..HEAD).
# Sets $output and $status via bats `run`.
# Optional third argument: path to a deny-list file to use.
# ---------------------------------------------------------------------------

_run_check() {
  local filename="$1"
  local content="$2"
  local denylist="${3:-}"

  local tmpdir
  tmpdir="$(mktemp -d)"

  local out
  local rc=0
  out=$(
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "ci@example.com"
    git config user.name "CI"
    git commit -q --allow-empty -m "init"
    printf '%s' "$content" > "$filename"
    git add "$filename"
    git commit -q -m "add file"
    if [[ -n "$denylist" ]]; then
      CAST_PII_LOCAL_DENYLIST="$denylist" bash "$SCRIPT" < /dev/null 2>&1
    else
      CAST_PII_LOCAL_DENYLIST="/nonexistent/path/pii-denylist-local.txt" bash "$SCRIPT" < /dev/null 2>&1
    fi
  ) || rc=$?

  rm -rf "$tmpdir"

  output="$out"
  status="$rc"
}

# ---------------------------------------------------------------------------
# Helper: test Check 1 specifically by placing a .bats file inside tests/ of
# a fresh tmp repo. Check 1 greps REPO_ROOT/tests — so we need the right dir
# structure, not just a diff payload.
# $1: bats file content to plant in tests/fixture.bats
# ---------------------------------------------------------------------------

_run_check1() {
  local content="$1"

  local tmpdir
  tmpdir="$(mktemp -d)"

  local out
  local rc=0
  out=$(
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "ci@example.com"
    git config user.name "CI"
    git commit -q --allow-empty -m "init"
    mkdir -p tests
    printf '%s' "$content" > tests/fixture.bats
    git add tests/fixture.bats
    git commit -q -m "add fixture"
    CAST_PII_LOCAL_DENYLIST="/nonexistent/path/pii-denylist-local.txt" bash "$SCRIPT" < /dev/null 2>&1
  ) || rc=$?

  rm -rf "$tmpdir"

  output="$out"
  status="$rc"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  cd "$REPO_DIR"
  # Create a BATS-scoped deny-list with FAKE test patterns only.
  FAKE_DENYLIST="$(mktemp)"
  printf '# BATS fake deny-list — test patterns only\nacmecorp\nsecret-project-x\n' > "$FAKE_DENYLIST"
}

teardown() {
  cd "$REPO_DIR"
  rm -f "$FAKE_DENYLIST"
}

# ---------------------------------------------------------------------------
# Test: clean push passes
# ---------------------------------------------------------------------------

@test "clean file with no PII passes the gate" {
  _run_check "clean.sh" "echo hello world" "$FAKE_DENYLIST"
  assert_success
}

# ---------------------------------------------------------------------------
# Test: Check 1 — hardcoded /Users/ path portability gate
# ---------------------------------------------------------------------------

@test "Check 1: real username /Users/somerealname123 in tests/ fails gate" {
  _run_check1 "path=/Users/somerealname123/projects/secret"
  assert_failure
  assert_output --partial "FAIL: Found hardcoded /Users/ paths"
}

@test "Check 1: /Users/testuser in tests/ does not fail gate (excluded fixture)" {
  _run_check1 "path=/Users/testuser/workspace"
  assert_success
  assert_output --partial "PASS: No hardcoded /Users/ paths found"
}

@test "Check 1: /Users/runner in tests/ does not fail gate (CI runner exclusion)" {
  _run_check1 "path=/Users/runner/work/repo"
  assert_success
  assert_output --partial "PASS: No hardcoded /Users/ paths found"
}

# ---------------------------------------------------------------------------
# Test: generic email scan blocks real addresses
# ---------------------------------------------------------------------------

@test "generic email address in diff blocks push" {
  _run_check "contact.txt" "contact: someone@gmail.com" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "email"
}

@test "noreply github address does not block" {
  _run_check "contact.txt" "Co-Authored-By: User <12345+handle@users.noreply.github.com>" "$FAKE_DENYLIST"
  assert_success
}

@test "noreply anthropic address does not block" {
  _run_check "contact.txt" "author: noreply@anthropic.com" "$FAKE_DENYLIST"
  assert_success
}

@test "example.com address does not block" {
  _run_check "contact.txt" "email: user@example.com" "$FAKE_DENYLIST"
  assert_success
}

# ---------------------------------------------------------------------------
# Test: generic hardcoded home-path scan
# ---------------------------------------------------------------------------

@test "hardcoded /Users/janedoe path in diff blocks push" {
  _run_check "paths.txt" "path=/Users/janedoe/projects/secret" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "hardcoded-path"
}

@test "/Users/testuser path does not block (excluded CI fixture)" {
  _run_check "paths.txt" "path=/Users/testuser/workspace" "$FAKE_DENYLIST"
  assert_success
}

@test "/Users/runner path does not block (GitHub macOS CI runner)" {
  _run_check "paths.txt" "path=/Users/runner/work/repo" "$FAKE_DENYLIST"
  assert_success
}

# ---------------------------------------------------------------------------
# Test: local deny-list mechanism with fake patterns
# ---------------------------------------------------------------------------

@test "local deny-list pattern 'acmecorp' in diff blocks push" {
  _run_check "remote.txt" "remote: bitbucket.org/acmecorp/myrepo" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "local-denylist"
}

@test "mixed-case deny-list pattern 'Secret-Project-X' blocks push" {
  # The deny-list has 'secret-project-x' (lowercase); matching must be case-insensitive.
  _run_check "notes.txt" "# Secret-Project-X plugin config" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "local-denylist"
}

@test "content matching neither deny-list pattern nor other scans passes" {
  _run_check "readme.txt" "# Generic open-source project description" "$FAKE_DENYLIST"
  assert_success
}

# ---------------------------------------------------------------------------
# Test: missing deny-list file does not fail
# ---------------------------------------------------------------------------

@test "missing deny-list file prints NOTE and does not fail the gate" {
  _run_check "clean.sh" "echo safe" "/nonexistent/path/no-denylist.txt"
  # Script must not exit with failure due to missing deny-list alone
  assert_success
  assert_output --partial "NOTE"
}

# ---------------------------------------------------------------------------
# Test: secret format scans (unchanged)
# ---------------------------------------------------------------------------

@test "Anthropic API key pattern in diff blocks push" {
  local key
  key="sk-ant-""api01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  _run_check ".env.test" "ANTHROPIC_API_KEY=$key" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "anthropic-key"
}

@test "GitHub PAT ghp_ prefix in diff blocks push" {
  local pat
  pat="ghp_""AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  _run_check "tokens.txt" "GITHUB_TOKEN=$pat" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "github-pat"
}

@test "GitHub token gho_ prefix in diff blocks push" {
  local pat
  pat="gho_""AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  _run_check "tokens.txt" "GITHUB_TOKEN=$pat" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "github-pat"
}

@test "GitHub token github_pat_ prefix in diff blocks push" {
  local pat
  pat="github_pat_""AAAAAAAAAAAAAAAAAAAAAA"
  _run_check "tokens.txt" "GITHUB_TOKEN=$pat" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "github-pat"
}

@test "AWS key pattern in diff blocks push" {
  local aws_key
  aws_key="AKIA""AAAAAAAAAAAAAAAA"
  _run_check "aws.txt" "AWS_ACCESS_KEY_ID=$aws_key" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "aws-key"
}

@test "Google OAuth secret pattern in diff blocks push" {
  local oauth_secret
  oauth_secret="GOCSPX-""abcdefghijklmnopqrstuvwxyz1234"
  _run_check "oauth.txt" "CLIENT_SECRET=$oauth_secret" "$FAKE_DENYLIST"
  assert_failure
  assert_output --partial "google-oauth"
}

# ---------------------------------------------------------------------------
# Test: escape hatch — CAST_SKIP_PII_CHECK=1 skips the PII gate in the hook
# ---------------------------------------------------------------------------

@test "CAST_SKIP_PII_CHECK=1 skips PII gate in pre-push hook" {
  local hook="$REPO_DIR/.githooks/pre-push"
  local out
  local rc=0
  out=$(
    export CAST_SKIP_PII_CHECK=1
    export CAST_SKIP_BATS_PUSH=1
    export CAST_SKIP_UBUNTU_CHECK=1
    bash "$hook" < /dev/null 2>&1
  ) || rc=$?

  output="$out"
  status="$rc"

  refute_output --partial "PII/secret check failed"
  assert_output --partial "Skipping PII check"
}

# ---------------------------------------------------------------------------
# Test: new-branch push (all-zeros remote SHA) uses merge-base, not empty tree
# Regression for audit §3.8.D/E — empty-tree diff hung on ~540 files.
# ---------------------------------------------------------------------------

# Helper: simulate a new-branch push via stdin refs in an isolated repo.
# Creates a repo with a 'main' branch (so merge-base resolution works),
# then branches off, adds one commit, and feeds all-zeros remote SHA via stdin.
# Sets $output, $status, and $elapsed_seconds.
_run_new_branch_push() {
  local filename="$1"
  local content="$2"
  local denylist="${3:-/nonexistent/path/pii-denylist-local.txt}"

  local tmpdir
  tmpdir="$(mktemp -d)"

  local out rc=0 elapsed=0
  local start_ts end_ts
  start_ts="$(date +%s)"
  out=$(
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "ci@example.com"
    git config user.name "CI"
    # Establish a 'main' branch so merge-base resolution finds it.
    git commit -q --allow-empty -m "root"
    git checkout -b main -q 2>/dev/null || true
    git commit -q --allow-empty -m "main-base"
    # Branch off main and add one small commit.
    git checkout -b feature/regression-test -q
    printf '%s' "$content" > "$filename"
    git add "$filename"
    git commit -q -m "branch commit"
    local local_sha
    local_sha="$(git rev-parse HEAD)"
    # Feed the all-zeros remote SHA that a new-branch push produces.
    printf 'refs/heads/feature/regression-test %s refs/heads/feature/regression-test 0000000000000000000000000000000000000000\n' \
      "$local_sha" \
      | CAST_PII_LOCAL_DENYLIST="$denylist" bash "$SCRIPT" 2>&1
  ) || rc=$?
  end_ts="$(date +%s)"
  elapsed=$(( end_ts - start_ts ))

  rm -rf "$tmpdir"

  output="$out"
  status="$rc"
  elapsed_seconds="$elapsed"
}

@test "new-branch push (all-zeros remote SHA) exits 0 on clean small diff" {
  _run_new_branch_push "safe.txt" "echo hello world"
  assert_success
  assert_output --partial "All checks passed"
}

@test "new-branch push (all-zeros remote SHA) completes in under 10 seconds" {
  _run_new_branch_push "safe.txt" "echo hello world"
  # Guard: if elapsed is empty the helper failed to capture it; fail explicitly.
  [[ -n "${elapsed_seconds:-}" ]] || fail "elapsed_seconds not set by helper"
  if (( elapsed_seconds >= 10 )); then
    fail "New-branch push scan took ${elapsed_seconds}s — expected < 10s (merge-base fix may have regressed)"
  fi
}

@test "new-branch push still detects PII in the new commits" {
  local fake_denylist
  fake_denylist="$(mktemp)"
  printf '# BATS regression deny-list\nacmecorp\n' > "$fake_denylist"
  _run_new_branch_push "leak.txt" "remote: bitbucket.org/acmecorp/myrepo" "$fake_denylist"
  rm -f "$fake_denylist"
  assert_failure
  assert_output --partial "local-denylist"
}
