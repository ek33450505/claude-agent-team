#!/usr/bin/env bats
# tests/ci-pii-scan.bats — BATS tests for scripts/ci-pii-scan.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/ci-pii-scan.sh"

# ---------------------------------------------------------------------------
# Helper: run ci-pii-scan.sh against a fresh isolated git repo.
# Plants the given content in a file, tracks it, then runs the scan.
# Sets $output and $status via bats `run`.
# Args: $1=filename (relative) $2=file-content
# ---------------------------------------------------------------------------
_run_scan() {
  local filename="$1"
  local content="$2"

  local tmpdir
  tmpdir="$(mktemp -d)"

  local out
  local rc=0
  out=$(
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "ci@example.com"
    git config user.name "CI"
    # Create file and track it (git ls-files needs it staged/tracked)
    mkdir -p "$(dirname "$filename")"
    printf '%s' "$content" > "$filename"
    git add "$filename"
    bash "$SCRIPT" 2>&1
  ) || rc=$?

  rm -rf "$tmpdir"

  output="$out"
  status="$rc"
}

# ---------------------------------------------------------------------------
# 1. Clean tree passes
# ---------------------------------------------------------------------------
@test "clean tree: exits 0 with no findings" {
  _run_scan "src/main.sh" '#!/usr/bin/env bash
echo "hello world"
export USER_DIR="/home/user/stuff"
'
  assert_success
  assert_output --partial "All checks passed"
}

# ---------------------------------------------------------------------------
# 2. Hardcoded /Users/<realname> path is detected
# ---------------------------------------------------------------------------
@test "planted /Users/realname path: exits 1" {
  _run_scan "scripts/deploy.sh" '#!/usr/bin/env bash
# deploy helper
DEPLOY_PATH="/Users/johnsmith/Projects/myapp"
echo "$DEPLOY_PATH"
'
  assert_failure
  assert_output --partial "hardcoded-path"
  assert_output --partial "johnsmith"
}

# ---------------------------------------------------------------------------
# 3. Allowlisted usernames pass (testuser, runner, janedoe)
# ---------------------------------------------------------------------------
@test "testuser path: passes (allowlisted placeholder)" {
  _run_scan "tests/fixture.bats" '#!/usr/bin/env bats
@test "path portability" {
  run bash -c "ls /Users/testuser/config"
  assert_failure
}
'
  assert_success
  assert_output --partial "All checks passed"
}

@test "runner path: passes (CI placeholder)" {
  _run_scan "tests/fixture.sh" '#!/usr/bin/env bash
EXPECTED="/Users/runner/work/repo"
echo "$EXPECTED"
'
  assert_success
  assert_output --partial "All checks passed"
}

@test "janedoe path: passes (allowlisted fake user)" {
  _run_scan "tests/pii_test.sh" '#!/usr/bin/env bash
FAKE_PATH="/Users/janedoe/Projects/thing"
echo "$FAKE_PATH"
'
  assert_success
  assert_output --partial "All checks passed"
}

# ---------------------------------------------------------------------------
# 4. Email address is detected
# ---------------------------------------------------------------------------
@test "planted real email address: exits 1" {
  _run_scan "config/author.json" '{"author": "alice@realdomain.io", "version": "1.0"}'
  assert_failure
  assert_output --partial "email"
}

# ---------------------------------------------------------------------------
# 5. Allowlisted email patterns pass
# ---------------------------------------------------------------------------
@test "example.com email: passes (placeholder)" {
  _run_scan "config/template.json" '{"contact": "user@example.com"}'
  assert_success
  assert_output --partial "All checks passed"
}

@test "noreply github email: passes" {
  _run_scan "config/git.json" '{"email": "97137083+username@users.noreply.github.com"}'
  assert_success
  assert_output --partial "All checks passed"
}

# ---------------------------------------------------------------------------
# 6. sk-ant Anthropic key is detected
# ---------------------------------------------------------------------------
@test "planted sk-ant key: exits 1" {
  _run_scan "config/env_backup.sh" 'export ANTHROPIC_API_KEY="sk-ant-''api03-realkeyrealkeyrealkey1234567890ab"'
  assert_failure
  assert_output --partial "anthropic-key"
}

# ---------------------------------------------------------------------------
# 7. GitHub PAT is detected
# ---------------------------------------------------------------------------
@test "planted github PAT (ghp_): exits 1" {
  _run_scan "scripts/release.sh" 'GH_TOKEN="ghp_''abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"'
  assert_failure
  assert_output --partial "github-pat"
}

# ---------------------------------------------------------------------------
# 8. AWS key is detected
# ---------------------------------------------------------------------------
@test "planted AWS access key: exits 1" {
  _run_scan "config/aws.sh" 'export AWS_ACCESS_KEY_ID="AKIA''IOSFODNN7EXAMPLE"'
  assert_failure
  assert_output --partial "aws-key"
}

# ---------------------------------------------------------------------------
# 9. Allowlisted files are skipped even when they contain trigger patterns
# ---------------------------------------------------------------------------
@test "pre-push-ci-check.sh is skipped even with trigger patterns" {
  # This test verifies that the real script is allowlisted. We simulate by
  # creating a file at that path in a fresh repo that contains a real-looking path.
  local tmpdir
  tmpdir="$(mktemp -d)"

  local out rc=0
  out=$(
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "ci@example.com"
    git config user.name "CI"
    mkdir -p scripts
    printf '%s\n' '#!/usr/bin/env bash' > scripts/pre-push-ci-check.sh
    printf '%s\n' '# /Users/johnsmith/Projects is documented here intentionally' >> scripts/pre-push-ci-check.sh
    git add scripts/pre-push-ci-check.sh
    bash "$SCRIPT" 2>&1
  ) || rc=$?

  rm -rf "$tmpdir"

  [[ $rc -eq 0 ]] || { echo "Expected exit 0, got $rc. Output: $out"; return 1; }
  echo "$out" | grep -q "All checks passed" || { echo "Expected 'All checks passed'. Output: $out"; return 1; }
}

# ---------------------------------------------------------------------------
# 10. --self-test flag works and exits 0
# ---------------------------------------------------------------------------
@test "--self-test exits 0 and reports PASSED" {
  run bash "$SCRIPT" --self-test
  assert_success
  assert_output --partial "--self-test PASSED"
}
