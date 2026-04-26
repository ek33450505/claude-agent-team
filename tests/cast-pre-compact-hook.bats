#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  unset CLAUDE_SUBPROCESS
  unset CAST_ALLOW_DIRTY_COMPACT
}

teardown() {
  [ -n "${TMP_REPO:-}" ] && rm -rf "$TMP_REPO"
}

@test "CAST_ALLOW_DIRTY_COMPACT=1: hook exits 0 even with staged changes" {
  # Create a temp git repo with a staged change
  TMP_REPO="$(mktemp -d)"
  git -C "$TMP_REPO" init -q
  git -C "$TMP_REPO" config user.email "test@test.com"
  git -C "$TMP_REPO" config user.name "Test"
  echo "dirty" > "$TMP_REPO/file.txt"
  git -C "$TMP_REPO" add file.txt
  # Hook reads INPUT from stdin; send minimal JSON
  run env CAST_ALLOW_DIRTY_COMPACT=1 \
          CLAUDE_SUBPROCESS=0 \
          bash "$REPO_ROOT/scripts/cast-pre-compact-hook.sh" <<< '{}'
  # Must exit 0 — bypass engaged
  assert_success
}

@test "without CAST_ALLOW_DIRTY_COMPACT, staged changes block compact" {
  TMP_REPO="$(mktemp -d)"
  git -C "$TMP_REPO" init -q
  git -C "$TMP_REPO" config user.email "test@test.com"
  git -C "$TMP_REPO" config user.name "Test"
  echo "dirty" > "$TMP_REPO/file.txt"
  git -C "$TMP_REPO" add file.txt
  # Run hook from inside the dirty repo directory
  run env CLAUDE_SUBPROCESS=0 \
          bash -c "cd '$TMP_REPO' && bash '$REPO_ROOT/scripts/cast-pre-compact-hook.sh'" <<< '{}'
  assert_failure
}
