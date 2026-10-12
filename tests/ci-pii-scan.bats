#!/usr/bin/env bats
# tests/ci-pii-scan.bats — BATS tests for scripts/ci-pii-scan.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

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
    git init -q || exit 97
    cast_git_fixture_quiet || exit 97
    git config user.email "ci@example.com" || exit 97
    git config user.name "CI" || exit 97
    # Create file and track it (git ls-files needs it staged/tracked)
    mkdir -p "$(dirname "$filename")" || exit 97
    printf '%s' "$content" > "$filename" || exit 97
    git add "$filename" || exit 97
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
# path portability fixture — testuser is an allowlisted placeholder path.
# Intentionally NOT a real @test block: a line-start @test inside this string
# literal is miscounted as a top-level test by bats 1.10 in the CI container,
# which breaks the suite plan (executed N-1 of N). Keep the path, drop the token.
ls /Users/testuser/config
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
    git init -q || exit 97
    cast_git_fixture_quiet || exit 97
    git config user.email "ci@example.com" || exit 97
    git config user.name "CI" || exit 97
    mkdir -p scripts || exit 97
    printf '%s\n' '#!/usr/bin/env bash' > scripts/pre-push-ci-check.sh || exit 97
    printf '%s\n' '# /Users/johnsmith/Projects is documented here intentionally' >> scripts/pre-push-ci-check.sh || exit 97
    git add scripts/pre-push-ci-check.sh || exit 97
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

# ---------------------------------------------------------------------------
# G1c-C: exclusions are per-MATCH and anchored to the whole match
# ---------------------------------------------------------------------------
@test "G1c-C flags example.com absorbed as a local part" {
  _run_scan "notes/a.txt" 'contact x@example.com.ed@corp.io today'
  assert_failure
  assert_output --partial "[email]"
}

@test "G1c-C flags noreply-domain absorbed as a local part" {
  _run_scan "notes/a.txt" 'contact users.noreply.github.com.ed@corp.io today'
  assert_failure
  assert_output --partial "[email]"
}

@test "G1c-C flags example.community (suffix, not example.com)" {
  _run_scan "notes/a.txt" 'contact bob@example.community today'
  assert_failure
  assert_output --partial "[email]"
}

@test "G1c-C flags evil-actions at github.com" {
  _run_scan "notes/a.txt" 'contact evil-actions@github.com today'
  assert_failure
  assert_output --partial "[email]"
}

@test "G1c-C flags /Users/runner.real" {
  _run_scan "notes/a.txt" 'path /Users/runner.real/x'
  assert_failure
  assert_output --partial "[hardcoded-path]"
}

@test "G1c-C flags /Users/testuser.alice" {
  _run_scan "notes/a.txt" 'path /Users/testuser.alice/x'
  assert_failure
  assert_output --partial "[hardcoded-path]"
}

@test "G1c-C flags a real address sharing a line with an excluded one" {
  _run_scan "notes/a.txt" 'cc noreply@anthropic.com and carol@corp.io'
  assert_failure
  assert_output --partial "[email]"
}

@test "G1c-C passes t@example.invalid" {
  _run_scan "notes/a.txt" 'contact t@example.invalid today'
  assert_success
}

@test "G1c-C passes /Users/alice and /Users/..." {
  _run_scan "notes/a.txt" 'see /Users/alice/x and /Users/.../y'
  assert_success
}

@test "G1c-C passes actions at github.com" {
  _run_scan "notes/a.txt" 'sender actions@github.com'
  assert_success
}

@test "G1c-C drift: exclusion constants byte-identical with pre-push-ci-check.sh" {
  local other="$REPO_DIR/scripts/pre-push-ci-check.sh" k a b
  for k in _EMAIL_EXCLUSION _PATH_EXCLUSION; do
    a="$(grep "^${k}=" "$SCRIPT")"
    b="$(grep "^${k}=" "$other")"
    [ -n "$a" ]
    [ "$a" = "$b" ]
  done
}

@test "G1c-C round 2: flags user@example.co.uk (real domain, not a placeholder)" {
  _run_scan "notes/a.txt" 'contact user@example.co.uk today'
  assert_failure
  assert_output --partial "[email]"
}

@test "G1c-C round 2: invalid UTF-8 byte does not hide a real address under a UTF-8 locale" {
  local loc="" l
  while IFS= read -r l; do
    case "$l" in
      en_US.UTF-8 | en_US.utf8) loc="$l"; break ;;
    esac
  done < <(locale -a 2>/dev/null || true)
  if [ -z "$loc" ]; then
    while IFS= read -r l; do
      if printf '%s\n' "$l" | grep -qiE 'utf-?8'; then loc="$l"; break; fi
    done < <(locale -a 2>/dev/null || true)
  fi
  [ -n "$loc" ] || skip "no UTF-8 locale available"
  export LC_ALL="$loc"
  _run_scan "notes/a.txt" "caf$(printf '\xe9') contact carol@corp.io"
  assert_failure
  assert_output --partial "[email]"
}
