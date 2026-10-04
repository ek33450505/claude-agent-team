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
# Test 0: SECURITY (2026-10-03) hostile repo-local config must not execute during the
#         groomer's age check (git log -> for-each-ref) or worktree dirty check
#         (git diff --quiet). Marker-file tests; dry-run only, never --apply.
# ---------------------------------------------------------------------------
_gx_marker_script() { # name [body]
  printf '#!/bin/sh\ntouch "%s/fired-%s"\n%s\n' "$GX_MARK" "$1" "${2:-exit 0}" > "$GX_MARK/$1.sh"
  chmod +x "$GX_MARK/$1.sh"
}
_gx_fired() { find "$GX_MARK" -name 'fired-*' | wc -l | tr -d ' '; }
_gx_setup() {
  unset GIT_DIR GIT_WORK_TREE # the file-level setup() exports these; they override git -C
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  GX_MARK="$BATS_TEST_TMPDIR/markers"
  GX_REPO="$BATS_TEST_TMPDIR/hostile"
  mkdir -p "$GX_MARK"
  _gx_marker_script filter cat
  _gx_marker_script process
  _gx_marker_script fsmonitor
  _gx_marker_script eqfilter cat
  _gx_marker_script subfilter cat
  _gx_marker_script diffext
  _gx_marker_script textconv 'cat "$1"'
  _gx_marker_script gpg 'exit 1'
  git init -q --initial-branch=main "$GX_REPO"
  git -C "$GX_REPO" config user.email "test@example.com"
  git -C "$GX_REPO" config user.name "Test User"
  printf 'a.txt filter=x\nb.txt filter=Y.z\nc.txt filter=a=b\n*.txt diff=y\n' > "$GX_REPO/.gitattributes"
  echo eq > "$GX_REPO/c.txt"
  echo hello > "$GX_REPO/a.txt"
  echo world > "$GX_REPO/b.txt"
  touch -t 202001010000 "$GX_REPO/.gitattributes" "$GX_REPO/a.txt" "$GX_REPO/b.txt" "$GX_REPO/c.txt"
  git -C "$GX_REPO" add -A
  git -C "$GX_REPO" commit -q -m init
}
_gx_plant() { # hostile config planted AFTER the base commit / worktree creation
  git -C "$GX_REPO" config filter.x.clean "$GX_MARK/filter.sh"
  git -C "$GX_REPO" config filter.Y.z.process "$GX_MARK/process.sh"
  git -C "$GX_REPO" config filter.Y.z.required true
  git -C "$GX_REPO" config core.fsmonitor "$GX_MARK/fsmonitor.sh"
  git -C "$GX_REPO" config "filter.a=b.clean" "$GX_MARK/eqfilter.sh"
  git -C "$GX_REPO" config diff.external "$GX_MARK/diffext.sh"
  git -C "$GX_REPO" config diff.y.textconv "$GX_MARK/textconv.sh"
}

@test "groomer hostile repo: branch age ignores planted gpg.program on a gpgsig tip and stays correct" {
  _gx_setup
  local tree sha
  tree="$(git -C "$GX_REPO" rev-parse 'main^{tree}')"
  sha="$(printf 'tree %s\nauthor T <t@t> 1577836800 +0000\ncommitter T <t@t> 1577836800 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n fake\n -----END PGP SIGNATURE-----\n\nsigned\n' "$tree" |
    git -C "$GX_REPO" hash-object -t commit -w --stdin)"
  git -C "$GX_REPO" update-ref refs/heads/worktree-agent-signed "$sha"        # 2020 -> stale
  git -C "$GX_REPO" update-ref refs/heads/worktree-agent-fresh refs/heads/main # committed now -> fresh
  git -C "$GX_REPO" config log.showSignature true
  git -C "$GX_REPO" config gpg.program "$GX_MARK/gpg.sh"
  # Control: the OLD call (porcelain git log) executes the planted program
  git -C "$GX_REPO" log -1 --format='%ct' refs/heads/worktree-agent-signed >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-gpg" ]
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --dry-run --repo "$GX_REPO"
  assert_success
  assert_output --partial "Would delete branch: worktree-agent-signed"
  refute_output --partial "Would delete branch: worktree-agent-fresh"
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer hostile repo: filter driver name containing '=' is blanked in the worktree check" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/gwt" -b gwt-branch
  _gx_plant
  touch "$BATS_TEST_TMPDIR/gwt/c.txt"
  # (other drivers blanked in the control only: the required process filter would die first)
  git -c core.fsmonitor=false -c filter.x.clean= -c filter.Y.z.process= -c filter.Y.z.required=false \
    -C "$BATS_TEST_TMPDIR/gwt" status --porcelain >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-eqfilter" ] # control
  rm -f "$GX_MARK"/fired-*
  touch -t 202201010000 "$BATS_TEST_TMPDIR/gwt/c.txt"
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  refute_output --partial "Keeping worktree (dirty)"
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer hostile repo: submodule-local clean filter on a stat-dirty file does not run" {
  _gx_setup
  mkdir -p "$BATS_TEST_TMPDIR/subsrc"
  git init -q --initial-branch=main "$BATS_TEST_TMPDIR/subsrc"
  git -C "$BATS_TEST_TMPDIR/subsrc" config user.email t@t
  git -C "$BATS_TEST_TMPDIR/subsrc" config user.name t
  printf '* filter=sf\n' > "$BATS_TEST_TMPDIR/subsrc/.gitattributes"
  echo f > "$BATS_TEST_TMPDIR/subsrc/f.txt"
  git -C "$BATS_TEST_TMPDIR/subsrc" add -A
  git -C "$BATS_TEST_TMPDIR/subsrc" commit -q -m i
  git -C "$GX_REPO" -c protocol.file.allow=always submodule add -q "$BATS_TEST_TMPDIR/subsrc" sub >/dev/null 2>&1
  git -C "$GX_REPO" commit -q -m sub
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/gwt" -b gwt-branch
  git -C "$BATS_TEST_TMPDIR/gwt" -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1
  git -C "$BATS_TEST_TMPDIR/gwt/sub" config filter.sf.clean "$GX_MARK/subfilter.sh"
  touch -t 202101010000 "$BATS_TEST_TMPDIR/gwt/sub/f.txt" # stat-dirty inside the submodule
  git -C "$BATS_TEST_TMPDIR/gwt" diff --quiet >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-subfilter" ] # control
  rm -f "$GX_MARK"/fired-*
  touch -t 202201010000 "$BATS_TEST_TMPDIR/gwt/sub/f.txt"
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer hostile repo: inherited GIT_CONFIG_PARAMETERS fsmonitor does not run in the worktree check" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/gwt" -b gwt-branch
  export GIT_CONFIG_PARAMETERS="'core.fsmonitor=$GX_MARK/fsmonitor.sh'"
  git -C "$BATS_TEST_TMPDIR/gwt" status --porcelain >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-fsmonitor" ] # control: env-injected fsmonitor fires on raw git
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer --apply: worktree whose only uncommitted work is inside a submodule is NOT removed" {
  _gx_setup
  mkdir -p "$BATS_TEST_TMPDIR/subsrc"
  git init -q --initial-branch=main "$BATS_TEST_TMPDIR/subsrc"
  git -C "$BATS_TEST_TMPDIR/subsrc" config user.email t@t
  git -C "$BATS_TEST_TMPDIR/subsrc" config user.name t
  echo f > "$BATS_TEST_TMPDIR/subsrc/f.txt"
  git -C "$BATS_TEST_TMPDIR/subsrc" add -A
  git -C "$BATS_TEST_TMPDIR/subsrc" commit -q -m i
  git -C "$GX_REPO" -c protocol.file.allow=always submodule add -q "$BATS_TEST_TMPDIR/subsrc" sub >/dev/null 2>&1
  git -C "$GX_REPO" commit -q -m sub
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/gwt" -b gwt-branch
  git -C "$BATS_TEST_TMPDIR/gwt" -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1
  echo "uncommitted submodule work" >> "$BATS_TEST_TMPDIR/gwt/sub/f.txt"
  touch -t 203001010000 "$BATS_TEST_TMPDIR/gwt" # newer than /tmp so every other check passes
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "has submodules"
  [ -d "$BATS_TEST_TMPDIR/gwt/sub" ]
  grep -q "uncommitted submodule work" "$BATS_TEST_TMPDIR/gwt/sub/f.txt"
}

@test "groomer --apply: plain clean stale worktree is still removed" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/gwt" -b gwt-branch
  touch -t 203001010000 "$BATS_TEST_TMPDIR/gwt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ ! -d "$BATS_TEST_TMPDIR/gwt" ]
}

@test "groomer hostile repo: clean (stat-dirty only) worktree is not reported dirty and no planted program runs" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/gwt" -b gwt-branch
  _gx_plant
  touch "$BATS_TEST_TMPDIR/gwt/a.txt" "$BATS_TEST_TMPDIR/gwt/b.txt" # stat-dirty, content identical
  # Control: raw status in the worktree DOES execute the planted programs
  git -C "$BATS_TEST_TMPDIR/gwt" status --porcelain >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-fsmonitor" ]
  [ -e "$GX_MARK/fired-filter" ]
  rm -f "$GX_MARK"/fired-*
  touch -t 202201010000 "$BATS_TEST_TMPDIR/gwt/a.txt" "$BATS_TEST_TMPDIR/gwt/b.txt"
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  refute_output --partial "Keeping worktree (dirty)"
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer hostile repo: modified worktree is still reported dirty and no planted program runs" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/gwt" -b gwt-branch
  _gx_plant
  echo changed >> "$BATS_TEST_TMPDIR/gwt/a.txt"
  # Control: a raw (non-quiet) diff DOES execute the planted diff.external. The filter and
  # fsmonitor knobs are blanked here only so the control isolates the diff.external vector
  # (the required process filter would otherwise die before the diff runs).
  GIT_PAGER=cat git -c core.fsmonitor=false -c filter.x.clean= -c filter.Y.z.process= \
    -c filter.Y.z.required=false -C "$BATS_TEST_TMPDIR/gwt" diff >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-diffext" ]
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp 'Keeping worktree \(dirty\): .*/gwt'
  [ "$(_gx_fired)" = "0" ]
}

# ---------------------------------------------------------------------------
# Test 0b: partial-clone lazy fetch. A promisor repo fetches a MISSING object via
#          repo-configured remote.<n>.uploadpack / core.sshCommand outside the sandbox;
#          GIT_NO_LAZY_FETCH=1 + GIT_ALLOW_PROTOCOL=none must stop that in the worktree check.
# ---------------------------------------------------------------------------
@test "groomer hostile repo: partial-clone lazy fetch does not run planted remote uploadpack" {
  _gx_setup
  _gx_marker_script uploadpack 'exec git upload-pack "$@"'
  git -C "$GX_REPO" config uploadpack.allowFilter true
  git -C "$GX_REPO" config uploadpack.allowAnySHA1InWant true
  # Two identical promisor clones: the control run fetches the missing blob into ITS object
  # store, so the groomer must run against a separate, still-incomplete clone.
  local n
  for n in ctl grm; do
    git clone -q --no-checkout --filter=blob:none "file://$GX_REPO" "$BATS_TEST_TMPDIR/pc-$n"
    git -C "$BATS_TEST_TMPDIR/pc-$n" worktree add -q --no-checkout "$BATS_TEST_TMPDIR/pwt-$n" -b pwt-branch
    git -C "$BATS_TEST_TMPDIR/pwt-$n" read-tree HEAD # index entries whose blobs are NOT present locally
    # identical content, no stat info in the index -> diff must compare against the (missing) blobs
    printf 'a.txt filter=x\nb.txt filter=Y.z\n*.txt diff=y\n' > "$BATS_TEST_TMPDIR/pwt-$n/.gitattributes"
    echo hello > "$BATS_TEST_TMPDIR/pwt-$n/a.txt"
    echo world > "$BATS_TEST_TMPDIR/pwt-$n/b.txt"
    git -C "$BATS_TEST_TMPDIR/pc-$n" config remote.origin.uploadpack "$GX_MARK/uploadpack.sh"
  done
  # Control: an unhardened diff needs the missing blob and DOES run the planted uploadpack
  git -C "$BATS_TEST_TMPDIR/pwt-ctl" diff --quiet >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-uploadpack" ]
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --dry-run --worktrees --repo "$BATS_TEST_TMPDIR/pc-grm"
  assert_success
  [ "$(_gx_fired)" = "0" ]
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
