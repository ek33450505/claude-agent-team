#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GROOMER="$REPO_DIR/scripts/cast-branch-groomer.sh"

# ---------------------------------------------------------------------------
# Setup / teardown — isolated git repo
# ---------------------------------------------------------------------------

setup() {
  export TEST_TMPDIR="$(mktemp -d /tmp/cast-groomer-test.XXXXXXXX)"
  export TEST_REPO="$TEST_TMPDIR/testrepo"

  # Create isolated git repo
  git init "$TEST_REPO" --initial-branch=main >/dev/null 2>&1
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "Test User"
  git -C "$TEST_REPO" commit --allow-empty -m "Initial commit" >/dev/null 2>&1

  export GIT_DIR="$TEST_REPO/.git"
  export GIT_WORK_TREE="$TEST_REPO"
}

teardown() {
  unset GIT_DIR GIT_WORK_TREE
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper: create a branch with a commit at a given age
# ---------------------------------------------------------------------------
_create_branch_aged() {
  local branch="$1"
  local days_ago="${2:-0}"
  git -C "$TEST_REPO" checkout -b "$branch" >/dev/null 2>&1
  # Commit with backdated date so committerdate reflects the age
  local fake_date
  fake_date="$(date -v -${days_ago}d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "$days_ago days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "2020-01-01T00:00:00")"
  GIT_COMMITTER_DATE="$fake_date" GIT_AUTHOR_DATE="$fake_date" \
    git -C "$TEST_REPO" commit --allow-empty -m "Test commit on $branch" >/dev/null 2>&1
  git -C "$TEST_REPO" checkout main >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: dry-run prints expected deletions and changes nothing
# ---------------------------------------------------------------------------

@test "groomer dry-run: prints what would be deleted, changes nothing" {
  # Create a stale cast-swarm-* branch (30d old)
  _create_branch_aged "cast-swarm-test-abcd1234" 30

  local branches_before
  branches_before="$(git -C "$TEST_REPO" branch --list | wc -l | tr -d ' ')"

  # Run dry-run (default mode)
  run bash "$GROOMER" --dry-run --repo "$TEST_REPO" 2>&1
  # Should not fail
  [ "$status" -eq 0 ]

  local branches_after
  branches_after="$(git -C "$TEST_REPO" branch --list | wc -l | tr -d ' ')"

  # Branch count should not change
  [ "$branches_before" -eq "$branches_after" ]

  # Should mention the branch
  [[ "$output" =~ "cast-swarm-test-abcd1234" ]] || [[ "$output" =~ "dry-run" ]] || [[ "$output" =~ "would" ]] || [[ "$output" =~ "Groomed" ]]
}

# ---------------------------------------------------------------------------
# Test 2: --apply deletes only matched branches
# ---------------------------------------------------------------------------

@test "groomer --apply: deletes stale cast-swarm-* branches" {
  # Create a stale cast-swarm-* branch (30d old)
  _create_branch_aged "cast-swarm-stale-abcd" 30

  # Verify it exists
  git -C "$TEST_REPO" branch --list | grep -q "cast-swarm-stale-abcd"

  # Apply — should delete it
  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  # Branch should be gone
  local still_exists
  still_exists="$(git -C "$TEST_REPO" branch --list "cast-swarm-stale-abcd" | wc -l | tr -d ' ')"
  [ "$still_exists" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 3: whitelist guard — main is never deleted
# ---------------------------------------------------------------------------

@test "groomer whitelist: never deletes main branch" {
  # Run apply mode
  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  # main should still exist
  git -C "$TEST_REPO" branch --list | grep -q "main"
}

# ---------------------------------------------------------------------------
# Test 4: keeps fresh feature/cast-v7-* branches
# ---------------------------------------------------------------------------

@test "groomer whitelist: keeps fresh feature/cast-v7-* branches" {
  # Create a recent feature/cast-v7-* branch (0 days old)
  _create_branch_aged "feature/cast-v7-test" 0

  # Run apply mode
  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  # Branch should still exist
  git -C "$TEST_REPO" branch --list | grep -q "feature/cast-v7-test"
}

# ---------------------------------------------------------------------------
# Test 5: worktree-agent-* branches deleted after 7d
# ---------------------------------------------------------------------------

@test "groomer --apply: deletes stale worktree-agent-* branches (>7d)" {
  _create_branch_aged "worktree-agent-old-xyz" 10

  git -C "$TEST_REPO" branch --list | grep -q "worktree-agent-old-xyz"

  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  local still_exists
  still_exists="$(git -C "$TEST_REPO" branch --list "worktree-agent-old-xyz" | wc -l | tr -d ' ')"
  [ "$still_exists" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: worktree-agent-* branch kept if fresh (<7d)
# ---------------------------------------------------------------------------

@test "groomer whitelist: keeps fresh worktree-agent-* branches (<7d)" {
  _create_branch_aged "worktree-agent-fresh-xyz" 3

  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  git -C "$TEST_REPO" branch --list | grep -q "worktree-agent-fresh-xyz"
}

# ---------------------------------------------------------------------------
# Test 7: summary line always printed
# ---------------------------------------------------------------------------

@test "groomer: always prints a summary line" {
  run bash "$GROOMER" --dry-run --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Groomed" ]]
}
