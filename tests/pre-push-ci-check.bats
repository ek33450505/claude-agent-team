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
    bash "$hook" < /dev/null 2>&1
  ) || rc=$?

  output="$out"
  status="$rc"

  refute_output --partial "PII/secret check failed"
  assert_output --partial "Skipping PII check"
}

# ---------------------------------------------------------------------------
# Tests: ubuntu CI-parity check is OPT-IN (2026-06-02 policy / 2026-06-30 fix)
# The hook no longer calls pre-push-ubuntu-check.sh by default; CAST_RUN_UBUNTU_PUSH=1
# is required. PATH-shims docker/make prevent any real container from spinning.
# ---------------------------------------------------------------------------

@test "ubuntu check is opt-in by default — prints opt-in message, does not invoke check" {
  local hook="$REPO_DIR/.githooks/pre-push"
  local fake_bin
  fake_bin="$(mktemp -d)"
  # Stub docker so the shim is there but the check is never reached (belt+suspenders).
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/docker"
  chmod +x "$fake_bin/docker"

  local out rc=0
  out=$(
    export CAST_SKIP_PII_CHECK=1
    export CAST_SKIP_STATS_PUSH=1
    export CAST_SKIP_DB_CONTRACT=1
    export CAST_SKIP_RULES_DRIFT=1
    export CAST_SKIP_README_STRUCTURE=1
    export PATH="$fake_bin:$PATH"
    bash "$hook" < /dev/null 2>&1
  ) || rc=$?

  rm -rf "$fake_bin"
  output="$out"
  status="$rc"

  assert_success
  assert_output --partial "opt-in"
  refute_output --partial "Running Ubuntu"
  refute_output --partial "Docker daemon not running"
}

@test "CAST_RUN_UBUNTU_PUSH=1 invokes the ubuntu check script (docker-shimmed to not run)" {
  local hook="$REPO_DIR/.githooks/pre-push"
  local fake_bin
  fake_bin="$(mktemp -d)"
  # Stub docker: command found but 'docker info' fails → "daemon not running" graceful exit 0.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/docker"
  chmod +x "$fake_bin/docker"
  # Stub make: must not be reached since docker daemon is shimmed to fail.
  printf '#!/usr/bin/env bash\necho "make: must not run in test" >&2; exit 1\n' > "$fake_bin/make"
  chmod +x "$fake_bin/make"

  local out rc=0
  out=$(
    export CAST_RUN_UBUNTU_PUSH=1
    export CAST_SKIP_PII_CHECK=1
    export CAST_SKIP_STATS_PUSH=1
    export CAST_SKIP_DB_CONTRACT=1
    export CAST_SKIP_RULES_DRIFT=1
    export CAST_SKIP_README_STRUCTURE=1
    export PATH="$fake_bin:$PATH"
    bash "$hook" < /dev/null 2>&1
  ) || rc=$?

  rm -rf "$fake_bin"
  output="$out"
  status="$rc"

  assert_success
  # Ubuntu-specific opt-in reminder must NOT appear — the check was attempted, not skipped.
  refute_output --partial "CAST_RUN_UBUNTU_PUSH=1 git push"
  # pre-push-ubuntu-check.sh should have fired and printed its graceful-skip message.
  assert_output --partial "Docker"
  refute_output --partial "make: must not run in test"
}

# ---------------------------------------------------------------------------
# Test: new-branch push (all-zeros remote SHA) scans only the pushed commits, not the whole repo
# Regression for audit §3.8.D/E — empty-tree diff hung on ~540 files.
# ---------------------------------------------------------------------------

# Helper: simulate a new-branch push via stdin refs in an isolated repo.
# Creates a repo with a 'main' branch, branches off and adds one commit, then feeds the
# all-zeros remote SHA via stdin with the remote name 'origin' as the gate's $1 (as the hook
# does). The repo has no remote-tracking refs, so every commit up to the branch tip is
# in the scanned range (`rev-list <tip> --not --remotes=origin`): a handful of tiny commits.
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
    # Establish a 'main' branch for the feature branch to start from.
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
      | CAST_PII_LOCAL_DENYLIST="$denylist" bash "$SCRIPT" origin 2>&1
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
    fail "New-branch push scan took ${elapsed_seconds}s — expected < 10s (scan cost regressed)"
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

# ---------------------------------------------------------------------------
# Per-commit scan (G1b): a literal added in one pushed commit and removed in a
# later commit of the SAME push never appears in `git diff <base> <local_sha>`
# but still lands in history (GitHub secret-scanning alert #2, 2026-10-09).
# ---------------------------------------------------------------------------

# Helper: build an isolated repo and feed one stdin push ref to the gate.
# $1 mode:
#   new      add-then-remove commits, all-zeros remote sha (new branch)
#   existing add-then-remove commits, remote sha = main's sha (existing remote branch)
#   delete   same history, but a branch-deletion line (all-zeros LOCAL sha)
#   bogus    existing remote sha, local sha that is not an object
#   merge    new branch whose only secret lives in a MERGE commit's resolution
#   unknownremote  add-then-remove commits, remote sha is NOT a local object (unfetched remote)
#   noupstream     no main/master/origin at all; the secret stays in the final tree
#   corrupt  existing remote; the first pushed commit's object is deleted (rev-list fails)
#   noblob   existing remote; the pushed file's blob is deleted (per-commit diff fails)
# $2 content written to .env.test (add-then-remove modes) or merge-added.txt (merge mode)
# Sets $output and $status.
_run_commit_range_push() {
  local mode="$1"
  local content="$2"

  local tmproot="${TMPDIR:-/tmp}"
  local tmpdir
  tmpdir="$(mktemp -d "$tmproot/range-test.XXXXXX")"

  local out rc=0
  out=$(
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "ci@example.com"
    git config user.name "CI"
    # noupstream: the only branch is 'trunk', so no origin/main|master or main|master exists.
    [[ "$mode" == "noupstream" ]] && git symbolic-ref HEAD refs/heads/trunk
    git commit -q --allow-empty -m "root"
    if [[ "$mode" != "noupstream" ]]; then
      git checkout -b main -q 2>/dev/null || true
      git commit -q --allow-empty -m "main-base"
    fi
    local main_sha zeros local_sha remote_sha add_sha blob_sha
    main_sha="$(git rev-parse HEAD)"
    zeros="0000000000000000000000000000000000000000"
    git checkout -b feature/range-test -q
    if [[ "$mode" == "noupstream" ]]; then
      printf '%s' "$content" > .env.test
      git add .env.test
      git commit -q -m "add"
    elif [[ "$mode" == "merge" ]]; then
      printf 'clean feature\n' > feat.txt
      git add feat.txt
      git commit -q -m "feature commit"
      git checkout -q -b side main
      printf 'clean side\n' > side.txt
      git add side.txt
      git commit -q -m "side commit"
      git checkout -q feature/range-test
      git merge -q --no-ff --no-commit side
      printf '%s' "$content" > merge-added.txt
      git add merge-added.txt
      git commit -q -m "merge side"
    else
      printf '%s' "$content" > .env.test
      git add .env.test
      git commit -q -m "add"
      add_sha="$(git rev-parse HEAD)"
      blob_sha="$(git rev-parse HEAD:.env.test)"
      git rm -q .env.test
      git commit -q -m "remove"
    fi
    local_sha="$(git rev-parse HEAD)"
    remote_sha="$zeros"
    # Corrupt the throwaway repo (never anything outside $tmpdir): loose object files are
    # <objects>/<2 hex>/<38 hex>.
    if [[ "$mode" == "corrupt" ]]; then
      rm -f ".git/objects/${add_sha:0:2}/${add_sha:2}"
    elif [[ "$mode" == "noblob" ]]; then
      rm -f ".git/objects/${blob_sha:0:2}/${blob_sha:2}"
    fi
    case "$mode" in
      existing | corrupt | noblob) remote_sha="$main_sha" ;;
      unknownremote) remote_sha="0123456789abcdef0123456789abcdef01234567" ;;
      delete)
        remote_sha="$main_sha"
        local_sha="$zeros"
        ;;
      bogus)
        remote_sha="$main_sha"
        local_sha="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        ;;
    esac
    printf 'refs/heads/feature/range-test %s refs/heads/feature/range-test %s\n' \
      "$local_sha" "$remote_sha" \
      | CAST_PII_LOCAL_DENYLIST="/nonexistent/path/pii-denylist-local.txt" bash "$SCRIPT" origin 2>&1
  ) || rc=$?

  # Only remove the dir we created, and only if it is under the temp root.
  if [[ -n "$tmpdir" && "$tmpdir" == "$tmproot"/range-test.* ]]; then
    rm -rf "$tmpdir"
  fi

  output="$out"
  status="$rc"
}

@test "per-commit scan: secret added then removed in one new-branch push blocks" {
  local aws_key
  aws_key="AKIA""AAAAAAAAAAAAAAAA"
  _run_commit_range_push new "AWS_ACCESS_KEY_ID=$aws_key"
  assert_failure
  assert_output --partial "aws-key"
}

@test "per-commit scan: secret added then removed in one existing-branch push blocks" {
  local aws_key
  aws_key="AKIA""AAAAAAAAAAAAAAAA"
  _run_commit_range_push existing "AWS_ACCESS_KEY_ID=$aws_key"
  assert_failure
  assert_output --partial "aws-key"
}

@test "per-commit scan: clean add-then-remove push still passes" {
  _run_commit_range_push new "echo hello world"
  assert_success
  assert_output --partial "All checks passed"
}

@test "per-commit scan: branch-deletion push (all-zeros local sha) exits 0" {
  local aws_key
  aws_key="AKIA""AAAAAAAAAAAAAAAA"
  _run_commit_range_push delete "AWS_ACCESS_KEY_ID=$aws_key"
  assert_success
  assert_output --partial "All checks passed"
}

@test "per-commit scan: local sha that is not a local commit fails closed" {
  _run_commit_range_push bogus "echo hello world"
  assert_failure
  assert_output --partial "is not a local commit"
  assert_output --partial "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
}

@test "per-commit scan: remote sha unknown locally still scans the branch (secret blocks)" {
  local aws_key
  aws_key="AKIA""AAAAAAAAAAAAAAAA"
  _run_commit_range_push unknownremote "AWS_ACCESS_KEY_ID=$aws_key"
  assert_failure
  assert_output --partial "aws-key"
  refute_output --partial "cannot enumerate"
}

@test "per-commit scan: remote sha unknown locally with clean content passes" {
  _run_commit_range_push unknownremote "echo hello world"
  assert_success
  assert_output --partial "All checks passed"
}

@test "per-commit scan: no default branch and no remote-tracking ref: pushed commits are still scanned" {
  local aws_key
  aws_key="AKIA""AAAAAAAAAAAAAAAA"
  _run_commit_range_push noupstream "AWS_ACCESS_KEY_ID=$aws_key"
  assert_failure
  assert_output --partial "aws-key"
}

@test "per-commit scan: unreadable commit history in the range fails closed" {
  _run_commit_range_push corrupt "echo hello world"
  assert_failure
  # The exact commit-enumeration message — the later merge-enumeration guard shares the
  # "cannot enumerate" prefix and would otherwise mask a removed primary guard.
  assert_output --partial "cannot enumerate pushed commits for"
}

@test "per-commit scan: a pushed commit whose patch cannot be read fails closed" {
  _run_commit_range_push noblob "echo hello world"
  assert_failure
  assert_output --partial "cannot diff pushed commit"
}

@test "per-commit scan: secret that exists only in a merge commit blocks (merge diffed against its parents)" {
  local aws_key
  aws_key="AKIA""AAAAAAAAAAAAAAAA"
  _run_commit_range_push merge "AWS_ACCESS_KEY_ID=$aws_key"
  assert_failure
  assert_output --partial "aws-key"
}

# ---------------------------------------------------------------------------
# Security / review round 1 (G1b): evil merge, header spoofing, binary / -diff,
# '++' content, remote-tracking range, orphan roots, deletion-only pushes, the
# commit cap and the standalone fallback.
# ---------------------------------------------------------------------------

# A fake credential built from fragments (never a literal in this file).
_fake_key() {
  printf '%s%s' "AKIA" "AAAAAAAAAAAAAAAA"
}

# Helper: isolated repo on branch 'main' holding one base commit (r.txt). Calls
# `<fn> [args...]` INSIDE the repo; the function makes commits and may set
#   LOCAL_SHA   pushed sha            (default: HEAD after fn)
#   REMOTE_SHA  remote sha on the ref (default: the base commit)
#   SC_NOSTDIN  =1 -> run the gate with no stdin ref line (standalone mode)
#   SC_SECOND_REF  a second ref name -> a second stdin line for the SAME shas (e.g. a tag)
# then feeds the stdin ref(s) to the gate. SC_BASH (outer env) picks the interpreter that runs
# the gate (default bash). Sets $output and $status.
_run_scenario() {
  local fn="$1"
  shift
  local tmproot="${TMPDIR:-/tmp}"
  local tmpdir
  tmpdir="$(mktemp -d "$tmproot/scenario.XXXXXX")"

  local out rc=0
  out=$(
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "ci@example.com"
    git config user.name "CI"
    git symbolic-ref HEAD refs/heads/main
    printf 'x\n' > r.txt
    git add r.txt
    git commit -q -m "base"
    REMOTE_SHA="$(git rev-parse HEAD)"
    LOCAL_SHA=""
    SC_NOSTDIN=0
    # git passes the remote name as the hook's $1; the hook forwards it to the gate.
    SC_REMOTE="${SC_REMOTE_OVERRIDE-origin}"
    "$fn" "$@"
    [[ -n "$LOCAL_SHA" ]] || LOCAL_SHA="$(git rev-parse HEAD)"
    if [[ "$SC_NOSTDIN" == "1" ]]; then
      CAST_PII_LOCAL_DENYLIST="/nonexistent/path/pii-denylist-local.txt" "${SC_BASH:-bash}" "$SCRIPT" < /dev/null 2>&1
    else
      {
        printf 'refs/heads/main %s refs/heads/main %s\n' "$LOCAL_SHA" "$REMOTE_SHA"
        if [[ -n "${SC_SECOND_REF:-}" ]]; then
          printf '%s %s %s %s\n' "$SC_SECOND_REF" "$LOCAL_SHA" "$SC_SECOND_REF" "$REMOTE_SHA"
        fi
      } | CAST_PII_LOCAL_DENYLIST="${SC_DENYLIST_OVERRIDE:-/nonexistent/path/pii-denylist-local.txt}" "${SC_BASH:-bash}" "$SCRIPT" "$SC_REMOTE" 2>&1
    fi
  ) || rc=$?

  if [[ -n "$tmpdir" && "$tmpdir" == "$tmproot"/scenario.* ]]; then
    rm -rf "$tmpdir"
  fi

  output="$out"
  status="$rc"
}

# --- scenario functions (run inside the throwaway repo) ---------------------

# $1 path, $2 content: one commit adding that file.
_sc_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
  git add -A
  git commit -q -m "add file"
}

# Secret added inside a MERGE commit, removed by the next commit.
_sc_evilmerge() {
  local key
  key="$(_fake_key)"
  git checkout -q -b side
  printf 'side\n' > side.txt
  git add side.txt
  git commit -q -m "side"
  git checkout -q main
  printf 'main\n' > main.txt
  git add main.txt
  git commit -q -m "main work"
  git merge -q --no-ff --no-commit side
  printf 'k=%s\n' "$key" > evil.txt
  git add evil.txt
  git commit -q -m "merge side"
  git rm -q evil.txt
  git commit -q -m "cleanup"
}

# A non-ASCII (quoted-header) file with a secret next to an ALLOWLISTED file edit.
# $1 = same (both in one commit) | cross (older commit adds the secret file, newer edits
# the allowlisted file, so the allowlisted diff is scanned first).
_sc_quoted() {
  local key uni
  key="$(_fake_key)"
  uni=$'\303\251.txt'
  mkdir -p config tests
  printf '{}\n' > config/pii-patterns.json
  printf 'x\n' > tests/pre-push-ci-check.bats
  git add -A
  git commit -q -m "allowlisted files"
  if [[ "$1" == "same" ]]; then
    printf '{"a":1}\n' > config/pii-patterns.json
    printf 'k=%s\n' "$key" > "$uni"
    git add -A
    git commit -q -m "edit allowlisted + add unicode file"
  else
    printf 'k=%s\n' "$key" > "$uni"
    git add -A
    git commit -q -m "add unicode file"
    printf 'y\n' > tests/pre-push-ci-check.bats
    git add -A
    git commit -q -m "edit allowlisted"
  fi
}

# Binary / -diff content with a secret. $1 = nul | attr
_sc_binary() {
  local key
  key="$(_fake_key)"
  if [[ "$1" == "nul" ]]; then
    printf '\000\001%s\n' "$key" > b.dat
    git add -A
    git commit -q -m "binary"
  else
    printf '*.lock -diff\n' > .gitattributes
    git add -A
    git commit -q -m "attrs"
    printf 'k=%s\n' "$key" > x.lock
    git add -A
    git commit -q -m "lock"
  fi
}

# Only a NON-origin remote-tracking ref exists; local main carries an unpushed secret
# (added on main, removed by the next commit). $1 = feat (new branch off main tip, zeros
# remote) | tip (new tag on the main tip, zeros remote).
_sc_nonorigin() {
  local key
  key="$(_fake_key)"
  git update-ref refs/remotes/backup/main "$REMOTE_SHA"
  printf 'k=%s\n' "$key" > s.txt
  git add -A
  git commit -q -m "main secret"
  git rm -q s.txt
  git commit -q -m "main cleanup"
  REMOTE_SHA="0000000000000000000000000000000000000000"
  if [[ "$1" == "feat" ]]; then
    git checkout -q -b feat
    printf 'f\n' > f.txt
    git add -A
    git commit -q -m "feat"
  fi
}

# Orphan (unrelated-history) branch: a root commit with a secret, removed by a later commit.
# $1 = zeros (new branch; origin/main exists) | known (remote sha = main's tip, a local commit).
_sc_orphan() {
  local key main_tip
  key="$(_fake_key)"
  main_tip="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$main_tip"
  git checkout -q --orphan orph
  git rm -rf -q .
  printf 'k=%s\n' "$key" > s.txt
  git add -A
  git commit -q -m "orphan root with secret"
  git rm -q s.txt
  printf 'ok\n' > ok.txt
  git add -A
  git commit -q -m "orphan cleanup"
  if [[ "$1" == "zeros" ]]; then
    REMOTE_SHA="0000000000000000000000000000000000000000"
  fi
}

# Deletion-only push where HEAD~1..HEAD carries a secret. $1 = zeros length.
_sc_deletion() {
  local key zeros
  key="$(_fake_key)"
  printf 'k=%s\n' "$key" > s.txt
  git add -A
  git commit -q -m "head commit carries a secret"
  zeros="$(printf '%0*d' "$1" 0)"
  LOCAL_SHA="$zeros"
}

# $1 = number of clean commits on top of the base.
_sc_n_commits() {
  local i
  for i in $(seq 1 "$1"); do
    printf 'c%s\n' "$i" > "f$i.txt"
    git add -A
    git commit -q -m "c$i"
  done
}

# Standalone run (no stdin ref) whose HEAD patch cannot be read: the blob is deleted.
_sc_standalone_unreadable() {
  local blob
  printf 'content\n' > u.txt
  git add -A
  git commit -q -m "unreadable"
  blob="$(git rev-parse HEAD:u.txt)"
  rm -f ".git/objects/${blob:0:2}/${blob:2}"
  SC_NOSTDIN=1
}

# --- tests -------------------------------------------------------------------

@test "per-commit scan: evil merge (secret added in the merge, removed next commit) blocks" {
  _run_scenario _sc_evilmerge
  assert_failure
  assert_output --partial "aws-key"
}

@test "header parse: ' b/' in a path cannot spoof the gate-script allowlist entry" {
  local key
  key="$(_fake_key)"
  _run_scenario _sc_file "zz b/scripts/pre-push-ci-check.sh" "k=$key"
  assert_failure
  assert_output --partial "aws-key"
}

@test "header parse: ' b/' in a path cannot spoof a plugin/ skip" {
  local key
  key="$(_fake_key)"
  _run_scenario _sc_file "zz b/plugin/x.txt" "k=$key"
  assert_failure
  assert_output --partial "aws-key"
}

@test "header parse: ' b/' in a path cannot spoof the pii-patterns allowlist entry" {
  local key
  key="$(_fake_key)"
  _run_scenario _sc_file "zz b/config/pii-patterns.json" "k=$key"
  assert_failure
  assert_output --partial "aws-key"
}

@test "header parse: a genuine allowlisted file is still skipped" {
  local key
  key="$(_fake_key)"
  _run_scenario _sc_file "config/pii-patterns.json" "k=$key"
  assert_success
  assert_output --partial "All checks passed"
}

@test "header parse: quoted-path header does not inherit the previous file's allowlist skip" {
  _run_scenario _sc_quoted same
  assert_failure
  assert_output --partial "aws-key"
}

@test "header parse: quoted-path header does not inherit an allowlist skip across commits" {
  _run_scenario _sc_quoted cross
  assert_failure
  assert_output --partial "aws-key"
}

@test "diff --text: a secret in a NUL-containing (binary) file blocks" {
  _run_scenario _sc_binary nul
  assert_failure
  assert_output --partial "aws-key"
}

@test "diff --text: a secret in a file with the -diff attribute blocks" {
  _run_scenario _sc_binary attr
  assert_failure
  assert_output --partial "aws-key"
}

@test "scan: added content starting with '++' is not mistaken for a +++ header" {
  local key
  key="$(_fake_key)"
  _run_scenario _sc_file "p.md" "++$key"
  assert_failure
  assert_output --partial "aws-key"
}

@test "range: unpushed main commits are scanned when the only remote is not origin (new branch)" {
  _run_scenario _sc_nonorigin feat
  assert_failure
  assert_output --partial "aws-key"
}

@test "range: unpushed main commits are scanned when the only remote is not origin (new tag)" {
  _run_scenario _sc_nonorigin tip
  assert_failure
  assert_output --partial "aws-key"
}

@test "range: orphan branch (new, origin/main exists) add-then-remove blocks" {
  _run_scenario _sc_orphan zeros
  assert_failure
  assert_output --partial "aws-key"
}

@test "range: orphan root commit with a removed secret blocks when the remote sha is main" {
  _run_scenario _sc_orphan known
  assert_failure
  assert_output --partial "aws-key"
}

@test "deletion-only push scans nothing and passes even if HEAD~1..HEAD holds a secret" {
  _run_scenario _sc_deletion 40
  assert_success
  assert_output --partial "All checks passed"
}

@test "deletion sentinel is any-length zeros (64-hex SHA-256 style)" {
  _run_scenario _sc_deletion 64
  assert_success
  assert_output --partial "All checks passed"
}

@test "commit cap: a push over CAST_PII_MAX_COMMITS fails closed" {
  export CAST_PII_MAX_COMMITS=2
  _run_scenario _sc_n_commits 3
  assert_failure
  assert_output --partial "scan cap"
}

@test "commit cap: a push at exactly the cap is scanned and passes" {
  export CAST_PII_MAX_COMMITS=3
  _run_scenario _sc_n_commits 3
  assert_success
  assert_output --partial "All checks passed"
}

@test "commit cap: a non-numeric CAST_PII_MAX_COMMITS fails closed" {
  export CAST_PII_MAX_COMMITS=lots
  _run_scenario _sc_n_commits 1
  assert_failure
  assert_output --partial "must be a non-negative integer"
}

@test "standalone fallback: an unreadable HEAD patch fails closed" {
  _run_scenario _sc_standalone_unreadable
  assert_failure
  assert_output --partial "cannot diff HEAD"
}

# ---------------------------------------------------------------------------
# Round 2 (G1b): byte-wise scanning, pinned diffs, grep errors, remote scoping,
# renames, standalone-outside-a-repo and cap parsing.
# ---------------------------------------------------------------------------

# $1 = invalid (an invalid UTF-8 byte BEFORE the secret on one line) | blob (binary bytes
# around an embedded key).
_sc_bytes() {
  local key
  key="$(_fake_key)"
  if [[ "$1" == "invalid" ]]; then
    printf '\377 k=%s\n' "$key" > bad.txt
  else
    printf '\377\376\000\200\201%s\377\n' "$key" > blob.bin
  fi
  git add -A
  git commit -q -m "bytes"
}

# $1 = ui | diff: git colour forced ON in the repo config; the commit carries a secret.
_sc_color() {
  git config "color.$1" always
  printf 'k=%s\n' "$(_fake_key)" > s.txt
  git add -A
  git commit -q -m "coloured"
}

# diff.noprefix=true drops the a/ b/ prefixes; the secret sits in an ALLOWLISTED file.
_sc_noprefix() {
  git config diff.noprefix true
  mkdir -p config
  printf 'k=%s\n' "$(_fake_key)" > config/pii-patterns.json
  git add -A
  git commit -q -m "allowlisted file under diff.noprefix"
}

# The secret commit is published ONLY on another remote's tracking ref (private/main).
_sc_crossremote() {
  printf 'k=%s\n' "$(_fake_key)" > s.txt
  git add -A
  git commit -q -m "secret on the private remote"
  git update-ref refs/remotes/private/main HEAD
  REMOTE_SHA="0000000000000000000000000000000000000000"
}

# A published secret (origin/main) with a clean feature commit on top; new branch.
_sc_published() {
  printf 'k=%s\n' "$(_fake_key)" > s.txt
  git add -A
  git commit -q -m "published secret"
  git update-ref refs/remotes/origin/main HEAD
  printf 'f\n' > f.txt
  git add -A
  git commit -q -m "feature"
  REMOTE_SHA="0000000000000000000000000000000000000000"
}

# A secret added to an ALLOWLISTED path, then a pure rename out of it.
_sc_rename() {
  mkdir -p tests docs
  printf 'k=%s\n' "$(_fake_key)" > tests/pre-push-ci-check.bats
  git add -A
  git commit -q -m "secret in an allowlisted path"
  git mv tests/pre-push-ci-check.bats docs/leak.txt
  git commit -q -m "rename out of the allowlisted path"
}

@test "locale: an invalid UTF-8 byte before a secret on the same line still blocks" {
  # Needs a UTF-8 locale to bite (BSD grep stops at the bad byte); elsewhere it is a no-op.
  export LC_ALL=en_US.UTF-8
  _run_scenario _sc_bytes invalid
  assert_failure
  assert_output --partial "aws-key"
}

@test "locale: a binary blob with an embedded key blocks" {
  export LC_ALL=en_US.UTF-8
  _run_scenario _sc_bytes blob
  assert_failure
  assert_output --partial "aws-key"
}

@test "diff pinning: color.ui=always in the repo config still blocks" {
  _run_scenario _sc_color ui
  assert_failure
  assert_output --partial "aws-key"
}

@test "diff pinning: color.diff=always in the repo config still blocks" {
  _run_scenario _sc_color diff
  assert_failure
  assert_output --partial "aws-key"
}

@test "diff pinning: diff.noprefix=true does not make an allowlisted file false-positive" {
  _run_scenario _sc_noprefix
  assert_success
  assert_output --partial "All checks passed"
}

@test "diff pinning: a pure rename out of an allowlisted path cannot launder a secret" {
  _run_scenario _sc_rename
  assert_failure
  assert_output --partial "aws-key"
}

@test "range: a secret published only to ANOTHER remote still blocks a push to origin" {
  export SC_REMOTE_OVERRIDE=origin
  _run_scenario _sc_crossremote
  assert_failure
  assert_output --partial "aws-key"
}

@test "range: the same push to the remote that holds the commit passes (control)" {
  export SC_REMOTE_OVERRIDE=private
  _run_scenario _sc_crossremote
  assert_success
  assert_output --partial "All checks passed"
}

@test "range: a hook argument that is not a plain remote name excludes nothing (over-scan)" {
  local r
  for r in "" "https://example.com/team/repo.git" "*" "or*"; do
    export SC_REMOTE_OVERRIDE="$r"
    _run_scenario _sc_published
    assert_failure
    assert_output --partial "aws-key"
  done
}

@test "range: with the real remote name its published commits are excluded (control)" {
  export SC_REMOTE_OVERRIDE=origin
  _run_scenario _sc_published
  assert_success
  assert_output --partial "All checks passed"
}

@test "deny-list: an invalid regex fails closed instead of silently matching nothing" {
  local dl
  dl="$(mktemp)"
  printf 'Users/(bob\n' > "$dl"
  export SC_DENYLIST_OVERRIDE="$dl"
  _run_scenario _sc_n_commits 1
  rm -f "$dl"
  assert_failure
  assert_output --partial "invalid deny-list pattern"
}

# Create a directory holding a `grep` shim that exits 2 whenever any argument contains the
# substring $1 and otherwise execs the real grep. Prints the directory (prefix it to PATH).
_make_grep_shim() {
  local shim real
  shim="$(mktemp -d "${TMPDIR:-/tmp}/grepshim.XXXXXX")"
  real="$(command -v grep)"
  printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *%s*) exit 2 ;; esac; done\nexec %s "$@"\n' "$1" "$real" > "$shim/grep"
  chmod +x "$shim/grep"
  printf '%s' "$shim"
}

_rm_grep_shim() {
  if [[ "$1" == "${TMPDIR:-/tmp}"/grepshim.* ]]; then
    rm -rf "$1"
  fi
}

# One added line that is a candidate email (so the exclusion grep runs). Built from fragments.
_sc_email_line() {
  printf 'contact: %s%s%s\n' "who" "@" "acme-test.invalid" > mail.txt
  git add -A
  git commit -q -m "email line"
}

@test "scan: a grep that exits 2 is a visible scan-error failure, not a silent pass" {
  local shim
  shim="$(_make_grep_shim AKIA)"
  export PATH="$shim:$PATH"
  _run_scenario _sc_n_commits 1
  _rm_grep_shim "$shim"
  assert_failure
  assert_output --partial "[scan-error] aws-key: grep rc=2"
}

@test "scan: an exclusion grep that exits 2 is a visible scan-error failure too" {
  local shim
  shim="$(_make_grep_shim noreply)"
  export PATH="$shim:$PATH"
  _run_scenario _sc_email_line
  _rm_grep_shim "$shim"
  assert_failure
  assert_output --partial "[scan-error] email: exclusion grep rc=2"
}

@test "standalone run outside a git repository fails closed" {
  local d out rc=0
  d="$(mktemp -d "${TMPDIR:-/tmp}/norepo.XXXXXX")"
  out=$(cd "$d" && env -u CAST_REPO_ROOT CAST_PII_LOCAL_DENYLIST="/nonexistent/path/pii-denylist-local.txt" bash "$SCRIPT" < /dev/null 2>&1) || rc=$?
  if [[ "$d" == "${TMPDIR:-/tmp}"/norepo.* ]]; then
    rm -rf "$d"
  fi
  output="$out"
  status="$rc"
  assert_failure
  assert_output --partial "not a git repository"
}

@test "commit cap: a leading-zero value is decimal (08 is 8 and still trips the cap)" {
  # Without 10#, "08" is an invalid octal: `(( n > 08 ))` errors, which reads as FALSE, so the
  # cap would silently never trip. 9 commits must exceed a cap of 08.
  export CAST_PII_MAX_COMMITS=08
  _run_scenario _sc_n_commits 9
  assert_failure
  assert_output --partial "scan cap"
}

@test "commit cap: a leading-zero value within the cap scans cleanly (no arithmetic error)" {
  export CAST_PII_MAX_COMMITS=08
  _run_scenario _sc_n_commits 3
  assert_success
  refute_output --partial "value too great"
  assert_output --partial "All checks passed"
}

@test "commit cap: a value of more than 9 digits fails closed" {
  export CAST_PII_MAX_COMMITS=1234567890
  _run_scenario _sc_n_commits 1
  assert_failure
  assert_output --partial "must be a non-negative integer"
}

# ---------------------------------------------------------------------------
# Single-pass scan (G1c): the diff is parsed once into line-aligned records and each pattern
# is ONE grep over them (was one grep per added line per pattern; 1,000 added lines took 272 s
# under /bin/bash 3.2).
# ---------------------------------------------------------------------------

# One commit adding big.txt (50,000 lines, a key on the LAST one) plus an ALLOWLISTED file that
# also holds a key (it must stay skipped). The lines are generated with awk (fast).
_sc_scale() {
  awk -v k="$(_fake_key)" 'BEGIN {
    for (i = 1; i < 50000; i++) printf "line %d filler text for the scale test\n", i
    printf "key=%s\n", k
  }' > big.txt
  mkdir -p tests
  printf 'k=%s\n' "$(_fake_key)" > tests/pre-push-ci-check.bats
  git add -A
  git commit -q -m "50k lines"
}

# One commit with a key, pushed on TWO refs (a branch and a tag) for the same shas.
_sc_two_refs() {
  printf 'k=%s\n' "$(_fake_key)" > s.txt
  git add -A
  git commit -q -m "secret"
  SC_SECOND_REF="refs/tags/v1"
}

# Files in diff (path) order: a.txt (clean, 3 lines), two ALLOWLISTED files and a plugin/ file
# that each hold a key (all skipped), then zz/b.txt whose 2nd line carries the key after a
# colon and a tab. The skipped files sit BETWEEN the clean file and the hit, so a name/content
# misalignment would attribute the hit to the wrong file.
_sc_aligned() {
  mkdir -p config plugin tests zz
  printf 'one\ntwo\nthree\n' > a.txt
  printf 'k=%s\n' "$(_fake_key)" > config/pii-patterns.json
  printf 'k=%s\n' "$(_fake_key)" > plugin/x.txt
  printf 'k=%s\n' "$(_fake_key)" > tests/pre-push-ci-check.bats
  printf 'first\nk: v\t=%s\nlast\n' "$(_fake_key)" > zz/b.txt
  git add -A
  git commit -q -m "aligned"
}

# A clean commit; the gate's TMPDIR is made unusable AFTER the repo is built (the scenario runs
# in a subshell, so the export reaches only the gate process).
_sc_badtmp() {
  _sc_file a.txt "clean"
  export TMPDIR=/nonexistent/cast-g1c
}

@test "scale: 50,000 added lines scan within 30 s under /bin/bash and still catch a key on the last line" {
  local t0 t1 elapsed
  t0="$(date +%s)"
  SC_BASH=/bin/bash _run_scenario _sc_scale
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  echo "# scale elapsed: ${elapsed}s" >&3
  assert_failure
  local n
  n="$(printf '%s\n' "$output" | grep -c '\[aws-key\]' || true)"
  [[ "$n" == "1" ]] || fail "expected exactly one [aws-key] line, got $n: $output"
  assert_output --partial "[aws-key] big.txt: key=$(_fake_key)"
  if ((elapsed >= 30)); then
    fail "50,000-line scan took ${elapsed}s under /bin/bash — expected < 30s (scan cost regressed)"
  fi
}

@test "scan: a commit pushed on two refs is diffed once" {
  _run_scenario _sc_two_refs
  assert_failure
  local n
  n="$(printf '%s\n' "$output" | grep -c '\[aws-key\]' || true)"
  [[ "$n" == "1" ]] || fail "expected exactly one [aws-key] line, got $n: $output"
}

@test "deny-list: a ^-anchored pattern anchors at the start of the added line's content" {
  local dl
  dl="$(mktemp)"
  printf '^acmecorp\n' > "$dl"
  export SC_DENYLIST_OVERRIDE="$dl"
  _run_scenario _sc_file x.txt "acmecorp here"
  rm -f "$dl"
  assert_failure
  assert_output --partial "[local-denylist] x.txt: acmecorp here"
}

@test "deny-list: the same ^-anchored pattern does not match content with a leading space (control)" {
  local dl
  dl="$(mktemp)"
  printf '^acmecorp\n' > "$dl"
  export SC_DENYLIST_OVERRIDE="$dl"
  _run_scenario _sc_file x.txt " acmecorp here"
  rm -f "$dl"
  assert_success
  refute_output --partial "[local-denylist]"
}

@test "scan: hit output keeps the file name and the full line (colon, tab) of a later file" {
  local expected
  expected="$(printf '  [aws-key] zz/b.txt: k: v\t=%s' "$(_fake_key)")"
  _run_scenario _sc_aligned
  assert_failure
  grep -Fxq -- "$expected" <<<"$output" || fail "no exact line [$expected] in: $output"
  local n
  n="$(printf '%s\n' "$output" | grep -c '\[aws-key\]' || true)"
  [[ "$n" == "1" ]] || fail "expected exactly one [aws-key] line, got $n: $output"
  refute_output --partial "] a.txt:"
  refute_output --partial "] config/pii-patterns.json:"
  refute_output --partial "] plugin/x.txt:"
  refute_output --partial "] tests/pre-push-ci-check.bats:"
}

@test "scratch dir: the gate leaves no cast-pii.* dir behind (pass and block)" {
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/g1c-tmp.XXXXXX")"
  TMPDIR="$t" _run_scenario _sc_file a.txt "clean"
  assert_success
  assert_output --partial "All checks passed"
  TMPDIR="$t" _run_scenario _sc_file a.txt "k=$(_fake_key)"
  assert_failure
  assert_output --partial "[aws-key]"
  local leaked=0
  if compgen -G "$t/cast-pii.*" >/dev/null; then
    leaked=1
  fi
  if [[ "$t" == "${TMPDIR:-/tmp}"/g1c-tmp.* ]]; then
    rm -rf "$t"
  fi
  [[ "$leaked" == "0" ]] || fail "the gate left a cast-pii.* scratch dir behind"
}

@test "scratch dir: an unusable TMPDIR fails closed" {
  _run_scenario _sc_badtmp
  assert_failure
  assert_output --partial "cannot create a private temp dir"
}

# Create a directory holding a `mktemp` shim: it runs the real mktemp and, ONLY when an
# argument contains `cast-pii.` (the gate's scratch dir), plants a dangling symlink
# hits -> missing/hits inside the new dir, so the gate's `>` onto it can never open. Prints the
# shim directory (prefix it to PATH). The real mktemp is resolved BEFORE PATH changes.
_make_mktemp_shim() {
  local shim real
  shim="$(mktemp -d "${TMPDIR:-/tmp}/mktempshim.XXXXXX")"
  real="$(command -v mktemp)"
  {
    printf '#!/bin/bash\n'
    printf 'd=$(%q "$@") || exit $?\n' "$real"
    printf 'for a in "$@"; do\n'
    printf '  case "$a" in\n'
    printf '    *cast-pii.*) ln -s "$d/missing/hits" "$d/hits"; break ;;\n'
    printf '  esac\n'
    printf 'done\n'
    printf 'printf "%%s\\n" "$d"\n'
  } > "$shim/mktemp"
  chmod +x "$shim/mktemp"
  printf '%s' "$shim"
}

_rm_mktemp_shim() {
  if [[ "$1" == "${TMPDIR:-/tmp}"/mktempshim.* ]]; then
    rm -rf "$1"
  fi
}

# 250 added lines that each hold a key (the printed hits are capped at 200 per pattern).
_sc_many() {
  awk -v k="$(_fake_key)" 'BEGIN { for (i = 1; i <= 250; i++) printf "k%d=%s\n", i, k }' > many.txt
  git add -A
  git commit -q -m "250 keys"
}

# 250 lines that the email exclusion suppresses (@example.com), then one real address in a LATER
# file. Built from fragments so no literal address sits in this file.
_sc_excluded() {
  local i
  for i in $(seq 1 250); do
    printf '%s%s%s\n' "u$i" "@" "example.com"
  done > e.txt
  printf '%s%s%s\n' "real" "@" "corp.test" > f.txt
  git add -A
  git commit -q -m "excluded then real"
}

# The base commit's r.txt is DELETED (a header with zero added lines) between a clean file and
# two files that hold a key: one allowlisted (skipped), one not. Header ordinals must stay
# aligned with the header list across the deletion and the skipped file.
_sc_delete_aligned() {
  rm -f r.txt
  mkdir -p tests zz
  printf 'one\ntwo\n' > a.txt
  printf 'k=%s\n' "$(_fake_key)" > tests/pre-push-ci-check.bats
  printf 'k=%s\n' "$(_fake_key)" > zz/b.txt
  git add -A
  git commit -q -m "delete and add"
}

@test "scratch: an output file that cannot be created is a scan-error, not a clean pass" {
  local shim
  shim="$(_make_mktemp_shim)"
  export PATH="$shim:$PATH"
  _run_scenario _sc_file s.txt "k=$(_fake_key)"
  _rm_mktemp_shim "$shim"
  assert_failure
  assert_output --partial "cannot write the scan scratch"
}

# Like _make_grep_shim, but the grep matching $1 exits 0 WITHOUT writing anything: "a match" with
# no hit lines (what a hits file pointing at /dev/null produces). Use _rm_grep_shim to remove it.
_make_silent_grep_shim() {
  local shim real
  shim="$(mktemp -d "${TMPDIR:-/tmp}/grepshim.XXXXXX")"
  real="$(command -v grep)"
  {
    printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *%s*) exit 0 ;; esac; done\n' "$1"
    printf 'exec %s "$@"\n' "$real"
  } > "$shim/grep"
  chmod +x "$shim/grep"
  printf '%s' "$shim"
}

@test "scan: a grep that reports a match but writes no hit is a scan-error, not a clean pass" {
  local shim
  shim="$(_make_silent_grep_shim AKIA)"
  export PATH="$shim:$PATH"
  _run_scenario _sc_n_commits 1
  _rm_grep_shim "$shim"
  assert_failure
  assert_output --partial "[scan-error] aws-key: grep reported a match but wrote no hits"
}

@test "scan: printed hits are capped at 200 per pattern" {
  _run_scenario _sc_many
  assert_failure
  local n
  n="$(printf '%s\n' "$output" | grep -c '\[aws-key\] many.txt: ' || true)"
  [[ "$n" == "200" ]] || fail "expected exactly 200 printed [aws-key] hit lines, got $n"
  grep -Fxq -- "  [aws-key] ... and 50 more hit lines not shown" <<<"$output" \
    || fail "no '... and 50 more hit lines not shown' line in: $output"
}

@test "scan: excluded lines do not consume the 200-hit cap" {
  _run_scenario _sc_excluded
  assert_failure
  grep -Fxq -- "  [email] f.txt: real@corp.test" <<<"$output" \
    || fail "no exact [email] f.txt line in: $output"
  refute_output --partial "[email] ... and"
}

@test "scan: header ordinals stay aligned across a deletion-only file" {
  _run_scenario _sc_delete_aligned
  assert_failure
  local n
  n="$(printf '%s\n' "$output" | grep -c '\[aws-key\]' || true)"
  [[ "$n" == "1" ]] || fail "expected exactly one [aws-key] line, got $n: $output"
  assert_output --partial "[aws-key] zz/b.txt: k=$(_fake_key)"
  refute_output --partial "] tests/pre-push-ci-check.bats:"
  refute_output --partial "] r.txt:"
}
