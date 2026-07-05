#!/usr/bin/env bats
# tests/cast-rollback.bats — Tests for scripts/cast-rollback.sh
#
# Uses a THROWAWAY temp git repo created inside BATS_TEST_TMPDIR.
# Never touches the real claude-agent-team repo or ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ROLLBACK_SCRIPT="$REPO_DIR/scripts/cast-rollback.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a throwaway git repo for rollback testing.
# Exports TEST_REPO and sets ROLLBACK_DIR under the temp HOME.
_make_test_repo() {
  export TEST_REPO="$BATS_TEST_TMPDIR/rollback-repo"
  mkdir -p "$TEST_REPO"
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "CAST Test"

  # Initial commit so HEAD is valid
  printf 'initial content\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add .
  git -C "$TEST_REPO" commit -q -m "initial"

  export ROLLBACK_DIR="$HOME/.claude/cast/rollback"
  mkdir -p "$ROLLBACK_DIR"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  _make_test_repo
}

teardown() {
  rm -rf "$TEST_REPO"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# @test (a): CAST_ROLLBACK_DRY_RUN=1 --yes previews diff, mutates nothing
# ---------------------------------------------------------------------------

@test "cast-rollback: dry-run previews diff and exits 0 without mutating working tree" {
  # Use the initial commit SHA as the checkpoint (regular commit, fine for dry-run)
  local checkpoint_sha
  checkpoint_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  printf '%s\n' "$checkpoint_sha" > "$ROLLBACK_DIR/batch-dry.sha"

  # Simulate a batch change: overwrite and commit
  printf 'batch modified\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add .
  git -C "$TEST_REPO" commit -q -m "batch changes"

  run bash -c "cd '$TEST_REPO' && env CAST_ROLLBACK_DRY_RUN=1 bash '$ROLLBACK_SCRIPT' --batch dry --yes"
  assert_success
  assert_output --partial "DRY RUN"

  # HEAD must still point to the batch changes commit — nothing was rolled back
  local content
  content="$(git -C "$TEST_REPO" show HEAD:file.txt)"
  [[ "$content" == "batch modified" ]]
}

# ---------------------------------------------------------------------------
# @test (b): real apply --yes restores checkpointed state via git stash apply
# ---------------------------------------------------------------------------

@test "cast-rollback: --yes skips prompt and stash apply restores file to stash state" {
  # Add a second file that the stash will record
  printf 'pre-batch content\n' > "$TEST_REPO/file-a.txt"
  git -C "$TEST_REPO" add file-a.txt
  git -C "$TEST_REPO" commit -q -m "add file-a"

  # Create an uncommitted working-tree change for file-a.txt
  printf 'stash content\n' > "$TEST_REPO/file-a.txt"

  # Capture the stash object SHA (git stash create records WD without resetting it)
  local stash_sha
  stash_sha="$(env CAST_STASH_OK=1 git -C "$TEST_REPO" stash create)"

  # Restore file-a.txt to its committed state (no uncommitted changes)
  printf 'pre-batch content\n' > "$TEST_REPO/file-a.txt"

  # Simulate batch: add a NEW file and commit (file-a.txt not touched, no conflicts)
  printf 'batch content\n' > "$TEST_REPO/file-b.txt"
  git -C "$TEST_REPO" add file-b.txt
  git -C "$TEST_REPO" commit -q -m "batch changes"

  run bash -c "cd '$TEST_REPO' && env CAST_STASH_OK=1 bash '$ROLLBACK_SCRIPT' --sha '$stash_sha' --yes"
  assert_success
  assert_output --partial "Rollback applied successfully"

  # file-a.txt must be restored to the stash content ("stash content")
  local content
  content="$(cat "$TEST_REPO/file-a.txt")"
  [[ "$content" == "stash content" ]]
}

# ---------------------------------------------------------------------------
# @test (c): stash-apply-fails -> per-file-checkout fallback
# ---------------------------------------------------------------------------

@test "cast-rollback: falls back to per-file checkout when stash apply fails" {
  # Record a REGULAR commit SHA as the checkpoint.
  # git stash apply will fail on a non-stash commit, triggering the fallback path.
  printf 'checkpoint content\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q -m "checkpoint"
  local checkpoint_sha
  checkpoint_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"

  printf '%s\n' "$checkpoint_sha" > "$ROLLBACK_DIR/batch-fallback.sha"

  # Simulate batch: overwrite and commit (HEAD now ahead of checkpoint)
  printf 'batch content\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q -m "batch changes"

  run bash -c "cd '$TEST_REPO' && bash '$ROLLBACK_SCRIPT' --batch fallback --yes"
  assert_success
  assert_output --partial "restored:"

  # file.txt must be restored to checkpoint content via the per-file checkout fallback
  local content
  content="$(cat "$TEST_REPO/file.txt")"
  [[ "$content" == "checkpoint content" ]]
}

# ---------------------------------------------------------------------------
# @test (d): CLEAN checkpoint early-exit no-ops, exits 0
# ---------------------------------------------------------------------------

@test "cast-rollback: CLEAN checkpoint exits 0 and leaves working tree untouched" {
  printf 'CLEAN\n' > "$ROLLBACK_DIR/batch-cleantest.sha"

  # Dirty working tree state that must NOT be reverted
  printf 'untouched dirty content\n' > "$TEST_REPO/file.txt"

  run bash -c "cd '$TEST_REPO' && bash '$ROLLBACK_SCRIPT' --batch cleantest --yes"
  assert_success
  assert_output --partial "clean tree"

  # Working tree must be unchanged (CLEAN guard exits before any apply)
  local content
  content="$(cat "$TEST_REPO/file.txt")"
  [[ "$content" == "untouched dirty content" ]]
}
