#!/usr/bin/env bats
# tests/cast-push.bats
# Validates scripts/cast-push.sh — specifically the pre-push SHA-capture fix
# that closes the mid-run commit false-verify race (2026-06-12).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-push.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Create a bare "origin" repo.
  ORIGIN_DIR="$(mktemp -d)"
  git init --bare -q "$ORIGIN_DIR"

  # Create a work repo seeded with one commit.
  WORK_DIR="$(mktemp -d)"
  git -C "$WORK_DIR" init -q
  git -C "$WORK_DIR" config user.email "cast-test@example.com"
  git -C "$WORK_DIR" config user.name "CAST Test"
  # Silence init.defaultBranch noise; pin to 'main'.
  git -C "$WORK_DIR" checkout -q -b main 2>/dev/null || true
  echo "initial" > "$WORK_DIR/file.txt"
  git -C "$WORK_DIR" add file.txt
  git -C "$WORK_DIR" commit -q -m "initial commit"
  git -C "$WORK_DIR" remote add origin "$ORIGIN_DIR"
}

teardown() {
  rm -rf "${ORIGIN_DIR:-}" "${WORK_DIR:-}" "${SHIM_DIR:-}"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1 — Happy path: successful push reports the pre-push SHA, exits 0.
# ---------------------------------------------------------------------------
@test "happy path: push exits 0 and reports the pushed SHA" {
  local expected_sha
  expected_sha=$(git -C "$WORK_DIR" rev-parse HEAD)

  run bash -c "cd '$WORK_DIR' && bash '$SCRIPT'"

  assert_success
  assert_output --partial "pushed and verified"
  assert_output --partial "$expected_sha"
}

# ---------------------------------------------------------------------------
# Test 2 — Race reproduction: a commit landing mid-push is detected as a
# mismatch (PUSH_SHA != REMOTE_SHA) and causes exit 1.
#
# Mechanism: a git shim earlier in PATH intercepts the 'push' subcommand,
# creates an extra commit in the work repo (simulating a mid-run commit),
# then execs the real git push.  Because the shim calls the real push with
# the new local HEAD, REMOTE_SHA will be the extra commit's SHA, while
# PUSH_SHA (captured before the push block) is still the original SHA.
# The fix detects this mismatch and exits 1.
#
# This test FAILS against the unfixed script: without pre-capturing PUSH_SHA,
# the script re-reads HEAD after the push and gets the extra commit's SHA,
# which matches REMOTE_SHA — producing a false-green exit 0.
# ---------------------------------------------------------------------------
@test "race: mid-push commit is detected as SHA mismatch (exit 1)" {
  # Build a PATH-prepended shim directory.
  SHIM_DIR="$(mktemp -d)"
  export SHIM_DIR

  # Write the shim.  It must locate the real git without re-entering itself.
  cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
# Find real git by walking PATH entries, skipping the shim directory.
REAL_GIT=""
IFS=: read -ra _DIRS <<< "$PATH"
for _d in "${_DIRS[@]}"; do
  if [[ "$_d" != "$SHIM_DIR" && -x "$_d/git" ]]; then
    REAL_GIT="$_d/git"
    break
  fi
done
if [[ -z "$REAL_GIT" ]]; then
  echo "git-shim: cannot locate real git" >&2
  exit 1
fi

# On push: create an extra commit before the real push so origin ends up at
# a SHA that was NOT the local HEAD when cast-push.sh started.
_is_push=0
for _arg in "$@"; do
  [[ "$_arg" == "push" ]] && { _is_push=1; break; }
done

if [[ "$_is_push" -eq 1 ]]; then
  echo "race" >> extra-race.txt
  "$REAL_GIT" add extra-race.txt
  "$REAL_GIT" -c user.email="r@r.r" -c user.name="Race" \
    commit -q -m "race: extra commit"
fi

exec "$REAL_GIT" "$@"
SHIM
  chmod +x "$SHIM_DIR/git"

  # Capture original SHA (what PUSH_SHA should be, captured before push).
  local original_sha
  original_sha=$(git -C "$WORK_DIR" rev-parse HEAD)

  # Run cast-push.sh with the shim first in PATH.
  run bash -c "export SHIM_DIR='$SHIM_DIR'; cd '$WORK_DIR' && PATH='$SHIM_DIR:$PATH' bash '$SCRIPT'"

  # With the fix: PUSH_SHA=original_sha, REMOTE_SHA=extra-commit-sha → mismatch → exit 1.
  # Without the fix: LOCAL_SHA re-read after push = extra-commit-sha = REMOTE_SHA → false exit 0.
  assert_failure
  assert_output --partial "SHA mismatch"
  # Error message must cite the original SHA (the pre-push value), not the new HEAD.
  assert_output --partial "$original_sha"
}

# ---------------------------------------------------------------------------
# Test 3 — Detached HEAD / no current branch: exits 1 with an error message.
# ---------------------------------------------------------------------------
@test "detached HEAD: exits 1 when current branch cannot be determined" {
  # Detach HEAD.
  git -C "$WORK_DIR" checkout -q --detach HEAD

  run bash -c "cd '$WORK_DIR' && bash '$SCRIPT'"

  assert_failure
  assert_output --partial "could not determine current branch"
}
