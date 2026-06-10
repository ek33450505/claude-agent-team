#!/usr/bin/env bats
# Tests for .githooks/post-merge
#
# Covers:
#   1. CAST source change (scripts/) → stub install IS invoked (marker created)
#   2. Non-CAST change (docs/ only)   → stub install NOT invoked
#   3. Missing ORIG_HEAD             → exits 0, no install
#   4. Escape hatch env var          → exits 0, no install
#
# Safety: uses an isolated temp git repo + temp HOME.
# NEVER runs real install.sh and NEVER touches real $HOME.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/.githooks/post-merge"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal git repo with one commit, then a second commit whose
# tree changes the given file path (relative). ORIG_HEAD will point to the
# first commit after we manually set it, simulating a completed merge.
_init_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.email "test@cast.local"
  git -C "$repo" config user.name "CAST Test"
  # Initial commit
  mkdir -p "$repo/scripts" "$repo/docs/tutorial"
  echo "v1" > "$repo/scripts/cast-init.sh"
  echo "v1" > "$repo/docs/README.md"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "initial"
}

# Make a second commit changing a specific file, then set ORIG_HEAD to the
# commit before it (simulating what git sets after a merge).
_second_commit() {
  local repo="$1"
  local file="$2"
  local content="${3:-changed}"
  mkdir -p "$repo/$(dirname "$file")"
  echo "$content" > "$repo/$file"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "change $file"
  # Store the previous HEAD as ORIG_HEAD (git does this on merge)
  git -C "$repo" rev-parse HEAD~1 > "$repo/.git/ORIG_HEAD"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  setup_temp_home
  export BATS_TEST_TMPDIR="$(mktemp -d)"
  export MARKER="$BATS_TEST_TMPDIR/installed.marker"
  # Stub install command: just touch a marker file
  export CAST_POST_MERGE_INSTALL_CMD="touch $MARKER"
  # Ensure no accidental skip
  unset CAST_SKIP_POST_MERGE_INSTALL 2>/dev/null || true
}

teardown() {
  rm -rf "$BATS_TEST_TMPDIR"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "CAST source change under scripts/ triggers install" {
  local repo="$BATS_TEST_TMPDIR/repo-scripts"
  _init_repo "$repo"
  _second_commit "$repo" "scripts/new-script.sh"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash "$HOOK"
  assert_success

  [ -f "$MARKER" ]
}

@test "CAST source change under agents/ triggers install" {
  local repo="$BATS_TEST_TMPDIR/repo-agents"
  _init_repo "$repo"
  mkdir -p "$repo/agents/core"
  _second_commit "$repo" "agents/core/my-agent.md"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash "$HOOK"
  assert_success

  [ -f "$MARKER" ]
}

@test "CAST source change under bin/ triggers install" {
  local repo="$BATS_TEST_TMPDIR/repo-bin"
  _init_repo "$repo"
  mkdir -p "$repo/bin"
  _second_commit "$repo" "bin/cast"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash "$HOOK"
  assert_success

  [ -f "$MARKER" ]
}

@test "CAST source change under rules-core/ triggers install" {
  local repo="$BATS_TEST_TMPDIR/repo-rules"
  _init_repo "$repo"
  mkdir -p "$repo/rules-core"
  _second_commit "$repo" "rules-core/shell.md"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash "$HOOK"
  assert_success

  [ -f "$MARKER" ]
}

@test "change only under docs/ does NOT trigger install" {
  local repo="$BATS_TEST_TMPDIR/repo-docs"
  _init_repo "$repo"
  _second_commit "$repo" "docs/README.md" "updated"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash "$HOOK"
  assert_success

  [ ! -f "$MARKER" ]
}

@test "change only under tests/ does NOT trigger install" {
  local repo="$BATS_TEST_TMPDIR/repo-tests"
  _init_repo "$repo"
  mkdir -p "$repo/tests"
  _second_commit "$repo" "tests/some.bats"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash "$HOOK"
  assert_success

  [ ! -f "$MARKER" ]
}

@test "missing ORIG_HEAD exits 0 and does NOT trigger install" {
  local repo="$BATS_TEST_TMPDIR/repo-no-orig"
  _init_repo "$repo"
  # Do NOT create ORIG_HEAD — simulate a fresh clone or first ever merge
  rm -f "$repo/.git/ORIG_HEAD"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash "$HOOK"
  assert_success

  [ ! -f "$MARKER" ]
}

@test "CAST_SKIP_POST_MERGE_INSTALL=1 exits 0 without install" {
  local repo="$BATS_TEST_TMPDIR/repo-skip"
  _init_repo "$repo"
  _second_commit "$repo" "scripts/something.sh"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" \
    CAST_SKIP_POST_MERGE_INSTALL=1 bash "$HOOK"
  assert_success

  [ ! -f "$MARKER" ]
}

@test "install command failure is non-fatal (hook still exits 0)" {
  local repo="$BATS_TEST_TMPDIR/repo-fail"
  _init_repo "$repo"
  _second_commit "$repo" "scripts/something.sh"

  run env GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" \
    CAST_POST_MERGE_INSTALL_CMD='false' bash "$HOOK"
  assert_success

  # Failure must be recorded in the log
  grep -q "install FAILED" "$HOME/.claude/logs/auto-install.log"
}
