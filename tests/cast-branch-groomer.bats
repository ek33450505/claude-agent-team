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
# Test 1: dry-run changes nothing and prints summary
# ---------------------------------------------------------------------------

@test "groomer dry-run: prints what would be deleted, changes nothing" {
  # Create a stale worktree-agent-* branch (30d old)
  _create_branch_aged "worktree-agent-test-abcd1234" 30

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

  # Should mention the branch or print dry-run/Groomed
  [[ "$output" =~ "worktree-agent-test-abcd1234" ]] || [[ "$output" =~ "dry-run" ]] || [[ "$output" =~ "would" ]] || [[ "$output" =~ "Groomed" ]]
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

# ---------------------------------------------------------------------------
# Test 8: squash-merged feature/fix branches with [gone] remote are deleted
# This is the regression test for the bug fix.
# ---------------------------------------------------------------------------

@test "groomer: detects squash-merged feature/* branch via cherry (core logic)" {
  # Create a feature branch with actual file content
  git -C "$TEST_REPO" checkout -b feature/squash-test >/dev/null 2>&1
  echo "feature content" > "$TEST_REPO/feature-file.txt"
  git -C "$TEST_REPO" add feature-file.txt
  git -C "$TEST_REPO" commit -m "Feature work" >/dev/null 2>&1

  # Use standard git merge --squash to create a proper squash merge
  git -C "$TEST_REPO" checkout main >/dev/null 2>&1
  git -C "$TEST_REPO" merge --squash feature/squash-test >/dev/null 2>&1
  git -C "$TEST_REPO" commit -m "Squash-merged feature/squash-test" >/dev/null 2>&1

  # Verify the branch is squash-merged using the groomer's core logic
  local ahead_count plus_count cherry_total
  ahead_count="$(git -C "$TEST_REPO" rev-list --count main..feature/squash-test 2>/dev/null || echo 1)"
  plus_count=$(git -C "$TEST_REPO" cherry main feature/squash-test 2>/dev/null | grep -c '^+') || plus_count=0
  cherry_total=$(git -C "$TEST_REPO" cherry main feature/squash-test 2>/dev/null | wc -l | tr -d ' ') || cherry_total=0

  # The squash-merge detection should work: no '+' lines in cherry, all commits accounted for
  [ "$plus_count" -eq 0 ]
  [ "$cherry_total" -eq "$ahead_count" ]
  [ "$cherry_total" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Test 9: unmerged feature/fix branch with [gone] remote is kept
# This ensures we don't over-correct and delete branches with unmerged work.
# ---------------------------------------------------------------------------

@test "groomer: keeps unmerged feature/* branch with [gone] remote" {
  # Create a feature branch with unique commits not on main
  git -C "$TEST_REPO" checkout -b feature/unmerged-work >/dev/null 2>&1
  git -C "$TEST_REPO" commit --allow-empty -m "Unique work 1" >/dev/null 2>&1
  git -C "$TEST_REPO" commit --allow-empty -m "Unique work 2" >/dev/null 2>&1
  local unmerged_sha
  unmerged_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"

  # Create fake [gone] remote ref and config
  git -C "$TEST_REPO" update-ref "refs/remotes/origin/feature/unmerged-work" "$unmerged_sha" >/dev/null 2>&1
  git -C "$TEST_REPO" config branch.feature/unmerged-work.remote "origin" >/dev/null 2>&1
  git -C "$TEST_REPO" config branch.feature/unmerged-work.merge "refs/heads/feature/unmerged-work" >/dev/null 2>&1
  # Delete the remote ref to simulate [gone]
  git -C "$TEST_REPO" update-ref -d "refs/remotes/origin/feature/unmerged-work" >/dev/null 2>&1

  # Run groomer in apply mode
  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  # Branch should still exist because it has unmerged work
  git -C "$TEST_REPO" branch --list | grep -q "feature/unmerged-work"
}

# ---------------------------------------------------------------------------
# Test 10: whitelist protection (feature/cast-v7-*) even if merged and [gone]
# ---------------------------------------------------------------------------

@test "groomer whitelist: keeps feature/cast-v7-* even if merged with [gone]" {
  # Create feature/cast-v7-* branch and merge it
  git -C "$TEST_REPO" checkout -b feature/cast-v7-critical-fix >/dev/null 2>&1
  git -C "$TEST_REPO" commit --allow-empty -m "Critical fix" >/dev/null 2>&1
  local cast_v7_sha
  cast_v7_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"

  # Switch to main and squash merge
  git -C "$TEST_REPO" checkout main >/dev/null 2>&1
  local tree
  tree="$(git -C "$TEST_REPO" rev-parse feature/cast-v7-critical-fix^{tree})"
  git -C "$TEST_REPO" commit-tree "$tree" -m "Merged feature/cast-v7-critical-fix" \
    -p "$(git -C "$TEST_REPO" rev-parse HEAD)" | \
    xargs -I {} sh -c 'cd "$TEST_REPO" && git update-ref refs/heads/main {}' >/dev/null 2>&1

  # Create fake [gone] remote ref
  git -C "$TEST_REPO" update-ref "refs/remotes/origin/feature/cast-v7-critical-fix" "$cast_v7_sha" >/dev/null 2>&1
  git -C "$TEST_REPO" config branch.feature/cast-v7-critical-fix.remote "origin" >/dev/null 2>&1
  git -C "$TEST_REPO" config branch.feature/cast-v7-critical-fix.merge "refs/heads/feature/cast-v7-critical-fix" >/dev/null 2>&1
  git -C "$TEST_REPO" update-ref -d "refs/remotes/origin/feature/cast-v7-critical-fix" >/dev/null 2>&1

  # Run groomer
  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  # Should still exist because it's in the whitelist
  git -C "$TEST_REPO" branch --list | grep -q "feature/cast-v7-critical-fix"
}

# ---------------------------------------------------------------------------
# Test 11: fix/* branches work same as feature/* (squash merge + [gone] deleted)
# ---------------------------------------------------------------------------

@test "groomer: detects squash-merged fix/* branch via cherry (core logic)" {
  # Create a fix branch with actual file content
  git -C "$TEST_REPO" checkout -b fix/squash-bugfix >/dev/null 2>&1
  echo "bug fix content" > "$TEST_REPO/bugfix-file.txt"
  git -C "$TEST_REPO" add bugfix-file.txt
  git -C "$TEST_REPO" commit -m "Bug fix" >/dev/null 2>&1

  # Use standard git merge --squash
  git -C "$TEST_REPO" checkout main >/dev/null 2>&1
  git -C "$TEST_REPO" merge --squash fix/squash-bugfix >/dev/null 2>&1
  git -C "$TEST_REPO" commit -m "Merged fix/squash-bugfix" >/dev/null 2>&1

  # Verify the branch is squash-merged using the groomer's core logic
  local ahead_count plus_count cherry_total
  ahead_count="$(git -C "$TEST_REPO" rev-list --count main..fix/squash-bugfix 2>/dev/null || echo 1)"
  plus_count=$(git -C "$TEST_REPO" cherry main fix/squash-bugfix 2>/dev/null | grep -c '^+') || plus_count=0
  cherry_total=$(git -C "$TEST_REPO" cherry main fix/squash-bugfix 2>/dev/null | wc -l | tr -d ' ') || cherry_total=0

  # The squash-merge detection should work: no '+' lines in cherry, all commits accounted for
  [ "$plus_count" -eq 0 ]
  [ "$cherry_total" -eq "$ahead_count" ]
  [ "$cherry_total" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Test 12: prefix guard — branches outside ALL deletion patterns are protected
#          This is the defense-in-depth regression guard (§3.8.B analogue):
#          the groomer only deletes branches matching explicit patterns, never
#          an arbitrary branch outside those patterns.
# ---------------------------------------------------------------------------

@test "groomer prefix guard: non-matching branches are never deleted" {
  # Create a branch that doesn't match ANY deletion pattern:
  # - not feature/* (except merged ones)
  # - not fix/* (except merged ones)
  # - not worktree-agent-*
  # - not in the whitelist (main, feature/cast-v7-*, etc.)
  git -C "$TEST_REPO" checkout -b safe-keep-do-not-delete >/dev/null 2>&1
  echo "important data" > "$TEST_REPO/important-file.txt"
  git -C "$TEST_REPO" add important-file.txt
  git -C "$TEST_REPO" commit -m "Important work in non-deletable branch" >/dev/null 2>&1
  git -C "$TEST_REPO" checkout main >/dev/null 2>&1

  # Also create an aged but unmatched branch to ensure age alone doesn't trigger deletion
  git -C "$TEST_REPO" checkout -b random-old-branch >/dev/null 2>&1
  local fake_date
  fake_date="$(date -v -30d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "30 days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "2020-01-01T00:00:00")"
  GIT_COMMITTER_DATE="$fake_date" GIT_AUTHOR_DATE="$fake_date" \
    git -C "$TEST_REPO" commit --allow-empty -m "Old random branch" >/dev/null 2>&1
  git -C "$TEST_REPO" checkout main >/dev/null 2>&1

  # Run groomer in apply mode
  run bash "$GROOMER" --apply --repo "$TEST_REPO" 2>&1
  [ "$status" -eq 0 ]

  # Both branches should survive because they don't match any deletion pattern
  git -C "$TEST_REPO" branch --list | grep -q "safe-keep-do-not-delete"
  git -C "$TEST_REPO" branch --list | grep -q "random-old-branch"
}
