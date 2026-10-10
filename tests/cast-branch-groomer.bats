#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GROOMER="$REPO_DIR/scripts/cast-branch-groomer.sh"

# ---------------------------------------------------------------------------
# Setup / teardown — isolated git repo
# ---------------------------------------------------------------------------

setup() {
  # Everything lives under BATS_TEST_TMPDIR (bats removes it); isolated HOME so the groomer's
  # ~/.claude/logs side effects never touch the real one.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export TEST_TMPDIR="$BATS_TEST_TMPDIR/legacy"
  mkdir -p "$TEST_TMPDIR"
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
  # Destructive-path discipline: only ever remove a dir this test created under BATS_TEST_TMPDIR.
  if [ -n "${TEST_TMPDIR:-}" ] && [[ "$TEST_TMPDIR" == "$BATS_TEST_TMPDIR"/* ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
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
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  _gx_plant
  touch "$GX_REPO/.claude/worktrees/agent-gwt/c.txt"
  # (other drivers blanked in the control only: the required process filter would die first)
  git -c core.fsmonitor=false -c filter.x.clean= -c filter.Y.z.process= -c filter.Y.z.required=false \
    -C "$GX_REPO/.claude/worktrees/agent-gwt" status --porcelain >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-eqfilter" ] # control
  rm -f "$GX_MARK"/fired-*
  touch -t 202201010000 "$GX_REPO/.claude/worktrees/agent-gwt/c.txt"
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
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  git -C "$GX_REPO/.claude/worktrees/agent-gwt" -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1
  git -C "$GX_REPO/.claude/worktrees/agent-gwt/sub" config filter.sf.clean "$GX_MARK/subfilter.sh"
  touch -t 202101010000 "$GX_REPO/.claude/worktrees/agent-gwt/sub/f.txt" # stat-dirty inside the submodule
  git -C "$GX_REPO/.claude/worktrees/agent-gwt" diff --quiet >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-subfilter" ] # control
  rm -f "$GX_MARK"/fired-*
  touch -t 202201010000 "$GX_REPO/.claude/worktrees/agent-gwt/sub/f.txt"
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer hostile repo: inherited GIT_CONFIG_PARAMETERS fsmonitor does not run in the worktree check" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  export GIT_CONFIG_PARAMETERS="'core.fsmonitor=$GX_MARK/fsmonitor.sh'"
  git -C "$GX_REPO/.claude/worktrees/agent-gwt" status --porcelain >/dev/null 2>&1 || true
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
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  git -C "$GX_REPO/.claude/worktrees/agent-gwt" -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1
  echo "uncommitted submodule work" >> "$GX_REPO/.claude/worktrees/agent-gwt/sub/f.txt"
  touch -t 202001010000 "$GX_REPO/.claude/worktrees/agent-gwt" # older than 7 days so the age gate passes
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "has submodules"
  [ -d "$GX_REPO/.claude/worktrees/agent-gwt/sub" ]
  grep -q "uncommitted submodule work" "$GX_REPO/.claude/worktrees/agent-gwt/sub/f.txt"
}

@test "groomer --apply: plain clean stale worktree is still removed" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  touch -t 202001010000 "$GX_REPO/.claude/worktrees/agent-gwt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ ! -d "$GX_REPO/.claude/worktrees/agent-gwt" ]
}

@test "groomer hostile repo: clean (stat-dirty only) worktree is not reported dirty and no planted program runs" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  _gx_plant
  touch "$GX_REPO/.claude/worktrees/agent-gwt/a.txt" "$GX_REPO/.claude/worktrees/agent-gwt/b.txt" # stat-dirty, content identical
  # Control: raw status in the worktree DOES execute the planted programs
  git -C "$GX_REPO/.claude/worktrees/agent-gwt" status --porcelain >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-fsmonitor" ]
  [ -e "$GX_MARK/fired-filter" ]
  rm -f "$GX_MARK"/fired-*
  touch -t 202201010000 "$GX_REPO/.claude/worktrees/agent-gwt/a.txt" "$GX_REPO/.claude/worktrees/agent-gwt/b.txt"
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  refute_output --partial "Keeping worktree (dirty)"
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer hostile repo: modified worktree is still reported dirty and no planted program runs" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  _gx_plant
  echo changed >> "$GX_REPO/.claude/worktrees/agent-gwt/a.txt"
  # Control: a raw (non-quiet) diff DOES execute the planted diff.external. The filter and
  # fsmonitor knobs are blanked here only so the control isolates the diff.external vector
  # (the required process filter would otherwise die before the diff runs).
  GIT_PAGER=cat git -c core.fsmonitor=false -c filter.x.clean= -c filter.Y.z.process= \
    -c filter.Y.z.required=false -C "$GX_REPO/.claude/worktrees/agent-gwt" diff >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-diffext" ]
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp 'Keeping worktree \(dirty\): .*/agent-gwt'
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
    git -C "$BATS_TEST_TMPDIR/pc-$n" worktree add -q --no-checkout "$BATS_TEST_TMPDIR/pc-$n/.claude/worktrees/agent-pwt" -b pwt-branch
    git -C "$BATS_TEST_TMPDIR/pc-$n/.claude/worktrees/agent-pwt" read-tree HEAD # index entries whose blobs are NOT present locally
    # identical content, no stat info in the index -> diff must compare against the (missing) blobs
    printf 'a.txt filter=x\nb.txt filter=Y.z\n*.txt diff=y\n' > "$BATS_TEST_TMPDIR/pc-$n/.claude/worktrees/agent-pwt/.gitattributes"
    echo hello > "$BATS_TEST_TMPDIR/pc-$n/.claude/worktrees/agent-pwt/a.txt"
    echo world > "$BATS_TEST_TMPDIR/pc-$n/.claude/worktrees/agent-pwt/b.txt"
    git -C "$BATS_TEST_TMPDIR/pc-$n" config remote.origin.uploadpack "$GX_MARK/uploadpack.sh"
  done
  # Control: an unhardened diff needs the missing blob and DOES run the planted uploadpack
  git -C "$BATS_TEST_TMPDIR/pc-ctl/.claude/worktrees/agent-pwt" diff --quiet >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-uploadpack" ]
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --dry-run --worktrees --repo "$BATS_TEST_TMPDIR/pc-grm"
  assert_success
  [ "$(_gx_fired)" = "0" ]
}

# ---------------------------------------------------------------------------
# Test 0c: S3a-U2 — EVERY groomer git call goes through cast_git_safe. Mutating calls
#          (branch -d/-D, worktree remove) fire repo-planted hooks on bare git; the helper must
#          neutralise them, and any helper/git error must mean "keep", never "delete".
# ---------------------------------------------------------------------------
_gx_old_branch() { # <name> — a branch whose only commit is backdated to 2020; main stays checked out
  local when="2020-01-01T00:00:00 +0000"
  git -C "$GX_REPO" checkout -q -b "$1"
  GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" git -C "$GX_REPO" commit -q --allow-empty -m "old $1"
  git -C "$GX_REPO" checkout -q main
}
_gx_gone_branch() { # <name> [unique] — fix/* branch whose upstream is [gone]; "unique" adds an unmerged commit
  git -C "$GX_REPO" branch "$1" main
  # The fetch refspec is what lets `branch -vv` resolve the (missing) upstream ref and print [gone].
  git -C "$GX_REPO" config remote.origin.url "$BATS_TEST_TMPDIR/no-such-remote"
  git -C "$GX_REPO" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$GX_REPO" config "branch.$1.remote" origin
  git -C "$GX_REPO" config "branch.$1.merge" "refs/heads/$1"
  if [ "${2:-}" = unique ]; then
    git -C "$GX_REPO" checkout -q "$1"
    git -C "$GX_REPO" commit -q --allow-empty -m "unmerged work on $1"
    git -C "$GX_REPO" checkout -q main
  fi
}
_gx_branch_exists() { git -C "$GX_REPO" show-ref --verify --quiet "refs/heads/$1"; }
# PATH-shim git: SHIM_MODE picks the failure; everything else passes through to the real git.
#   cfg = fail the hardening config read   foreach = fail for-each-ref   cherry1 = fail the FIRST cherry
_gx_git_shim() {
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat > "$BATS_TEST_TMPDIR/shim/git" <<'SHIM'
#!/bin/sh
fail() { echo x >> "$SHIM_STATE/shim-hit"; echo "fatal: shim: injected failure" >&2; exit 128; }
for a in "$@"; do
  case "${SHIM_MODE:-}:$a" in
    cfg:--get-regexp) fail ;;
    foreach:for-each-ref) fail ;;
    cherry1:cherry) [ -e "$SHIM_STATE/shim-hit" ] || fail ;;
  esac
done
exec "$SHIM_REAL_GIT" "$@"
SHIM
  chmod +x "$BATS_TEST_TMPDIR/shim/git"
}
# cast_git_safe resolves git from a FIXED trusted list and never consults PATH, so a PATH shim is
# inert. Run the groomer from a COPY of its scripts (groomer + lib + fs helper) whose lib's
# git_candidates line names the shim; the rewrite is asserted so the shim cannot be silently bypassed.
_gx_shimmed_groomer() { # prints the path of the copied groomer
  local d="$BATS_TEST_TMPDIR/gscripts"
  mkdir -p "$d"
  chmod 755 "$BATS_TEST_TMPDIR/shim"
  cp "$REPO_DIR/scripts/cast-branch-groomer.sh" "$REPO_DIR/scripts/cast_groom_fs.py" "$d/"
  sed "s|^  local git_candidates=(.*)\$|  local git_candidates=(\"$BATS_TEST_TMPDIR/shim/git\")|" \
    "$REPO_DIR/scripts/cast-hook-lib.sh" > "$d/cast-hook-lib.sh"
  grep -qF "local git_candidates=(\"$BATS_TEST_TMPDIR/shim/git\")" "$d/cast-hook-lib.sh"
  printf '%s' "$d/cast-branch-groomer.sh"
}
_gx_run_shimmed() { # <mode> <groomer args...>
  local mode="$1" groomer
  shift
  groomer="$(_gx_shimmed_groomer)"
  run env SHIM_MODE="$mode" SHIM_REAL_GIT="$(command -v git)" \
    SHIM_STATE="$BATS_TEST_TMPDIR" bash "$groomer" "$@"
}

@test "groomer --apply hostile repo: branch deletion does not run reference-transaction hooks (classic hooksPath + config hook)" {
  _gx_setup
  # -x is UNMERGED (plain -d refuses -> the groomer falls back to -D); -m is fully merged into main
  # (fast-forwarded in, so -d itself succeeds). Both mutating calls must be hardened.
  _gx_old_branch worktree-agent-x
  _gx_old_branch worktree-agent-m
  git -C "$GX_REPO" merge -q --ff-only worktree-agent-m
  git -C "$GX_REPO" branch sibling
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  printf '#!/bin/sh\ntouch "%s/fired-classic-hook"\ncat >/dev/null\n' "$GX_MARK" > "$BATS_TEST_TMPDIR/hooks/reference-transaction"
  chmod +x "$BATS_TEST_TMPDIR/hooks/reference-transaction"
  git -C "$GX_REPO" config core.hooksPath "$BATS_TEST_TMPDIR/hooks"
  _gx_marker_script cfghook 'cat >/dev/null'
  git -C "$GX_REPO" config hook.x.event reference-transaction
  git -C "$GX_REPO" config hook.x.command "$GX_MARK/cfghook.sh"
  # Control: plain `git branch -d` on a sibling DOES fire the classic hook (and the config hook on git >= 2.54)
  git -C "$GX_REPO" branch -d sibling >/dev/null 2>&1
  [ -e "$GX_MARK/fired-classic-hook" ]
  local cfg_live=0
  if [ -e "$GX_MARK/fired-cfghook" ]; then
    cfg_live=1
  else
    echo "# note: this git does not run config hooks (< 2.54); asserting the classic hook only" >&3
  fi
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --apply --repo "$GX_REPO"
  assert_success
  assert_output --partial "Deleted branch: worktree-agent-x"
  assert_output --partial "Deleted branch: worktree-agent-m"
  run _gx_branch_exists worktree-agent-x # (`! cmd` would not trip errexit: use run + assert_failure)
  assert_failure
  run _gx_branch_exists worktree-agent-m
  assert_failure
  [ ! -e "$GX_MARK/fired-classic-hook" ]
  if [ "$cfg_live" = 1 ]; then
    [ ! -e "$GX_MARK/fired-cfghook" ]
  fi
}

@test "groomer hostile repo: planted core.fsmonitor does not run during a --worktrees dry-run dirty check" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-gwt" -b gwt-branch
  git -C "$GX_REPO" config core.fsmonitor "$GX_MARK/fsmonitor.sh"
  touch -t 202001010000 "$GX_REPO/.claude/worktrees/agent-gwt" # older than 7 days so the age gate passes
  # Control: plain `git status` in the worktree DOES run the planted program
  git -C "$GX_REPO/.claude/worktrees/agent-gwt" status --porcelain >/dev/null 2>&1 || true
  [ -e "$GX_MARK/fired-fsmonitor" ]
  rm -f "$GX_MARK"/fired-*
  run bash "$GROOMER" --dry-run --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Would remove worktree: "  # the dirty check ran and passed (it is what could fire fsmonitor)
  [ "$(_gx_fired)" = "0" ]
}

@test "groomer --apply: when the hardening read fails nothing is deleted (control: a healthy run deletes both)" {
  _gx_setup
  _gx_git_shim
  _gx_old_branch worktree-agent-x
  _gx_gone_branch fix/gone-merged
  _gx_run_shimmed cfg --apply --repo "$GX_REPO"
  assert_failure
  assert_output --partial "refusing to run git"
  [ -e "$BATS_TEST_TMPDIR/shim-hit" ] # the injected failure really fired
  _gx_branch_exists worktree-agent-x
  _gx_branch_exists fix/gone-merged
  # Control: same fixture, same shim on PATH but passing through -> both branches ARE deletable
  _gx_run_shimmed pass --apply --repo "$GX_REPO"
  assert_success
  assert_output --partial "Deleted branch: worktree-agent-x"
  assert_output --partial "Deleted branch: fix/gone-merged"
}

@test "groomer --apply: a for-each-ref error keeps a worktree-agent branch (age unknown is not 'ancient')" {
  _gx_setup
  _gx_git_shim
  _gx_old_branch worktree-agent-x
  _gx_run_shimmed foreach --apply --repo "$GX_REPO"
  assert_success
  [ -e "$BATS_TEST_TMPDIR/shim-hit" ]
  refute_output --partial "Deleted branch"
  _gx_branch_exists worktree-agent-x
  # Control: with a healthy for-each-ref the same branch is deleted
  _gx_run_shimmed pass --apply --repo "$GX_REPO"
  assert_success
  assert_output --partial "Deleted branch: worktree-agent-x"
}

@test "groomer --apply: a transient cherry error never reads as 'merged' for an UNMERGED fix/* branch" {
  _gx_setup
  _gx_git_shim
  _gx_gone_branch fix/unmerged-gone unique
  _gx_run_shimmed cherry1 --apply --repo "$GX_REPO"
  assert_success
  [ -e "$BATS_TEST_TMPDIR/shim-hit" ] # the first cherry call failed
  refute_output --partial "Deleted branch"
  _gx_branch_exists fix/unmerged-gone
}

@test "groomer: refuses to run ANY git when cast-hook-lib.sh cannot be loaded; an inherited loaded-guard does not defeat the lib" {
  _gx_setup
  _gx_old_branch worktree-agent-x
  mkdir -p "$BATS_TEST_TMPDIR/solo"
  cp "$GROOMER" "$BATS_TEST_TMPDIR/solo/cast-branch-groomer.sh" # deliberately NOT copying the lib
  run bash "$BATS_TEST_TMPDIR/solo/cast-branch-groomer.sh" --apply --repo "$GX_REPO"
  assert_failure
  assert_output --partial "refusing to run git"
  _gx_branch_exists worktree-agent-x
  # Control: the real script (lib beside it) works, even with the lib's loaded-guard inherited from the env
  run env _CAST_HOOK_LIB_LOADED=1 bash "$GROOMER" --apply --repo "$GX_REPO"
  assert_success
  assert_output --partial "Deleted branch: worktree-agent-x"
}

# ---------------------------------------------------------------------------
# Test 0d: S3a-U2b — --worktrees is a confused deputy unless the groomer proves the worktree is a
#          REAL agent worktree of THIS repo. .git/worktrees/<id>/{gitdir,commondir,HEAD} and the
#          worktree's .git file are agent-writable; `worktree remove --force` follows them.
# ---------------------------------------------------------------------------
# Forged registry entry aimed at <victim-dir> (which holds a precious, git-IGNORED sentinel so no content
# check can see it). self  = commondir ../.. (passes the identity gate; only the PATH gate stops it)
#                    other = commondir -> a different repo (checks read THAT repo's clean state)
_gx_deputy_fixture() { # <repo> <victim-dir> <self|other>
  local repo="$1" victim="$2" mode="$3" other="$1-other" adm sha
  git init -q --initial-branch=main "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base
  adm="$repo/.git/worktrees/x"
  mkdir -p "$adm" "$victim"
  echo precious > "$victim/keep-me.txt"
  if [ "$mode" = self ]; then
    sha="$(git -C "$repo" rev-parse HEAD)"
    printf '../..\n' > "$adm/commondir"
    printf 'keep-me.txt\n' >> "$repo/.git/info/exclude"
  else
    git init -q --initial-branch=main "$other"
    git -C "$other" config user.email t@t
    git -C "$other" config user.name t
    git -C "$other" commit -q --allow-empty -m base
    sha="$(git -C "$other" rev-parse HEAD)"
    printf '%s\n' "$other/.git" > "$adm/commondir"
    printf 'keep-me.txt\n' >> "$other/.git/info/exclude"
  fi
  printf '%s\n' "$sha" > "$adm/HEAD"
  printf '%s\n' "$victim/.git" > "$adm/gitdir"
  printf 'gitdir: %s\n' "$adm" > "$victim/.git"
  touch -t 202001010000 "$victim" # old: the (forgeable) age gate must not be what saves it
}
# A real, clean agent worktree whose path is then swapped for a symlink to <target>.
_gx_symlink_fixture() { # <repo> <target>
  git init -q --initial-branch=main "$1"
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  echo tracked > "$1/tracked.txt"
  git -C "$1" add -A
  git -C "$1" commit -q -m base
  git -C "$1" worktree add -q "$1/.claude/worktrees/agent-link" -b agent-link-branch
  mv "$1/.claude/worktrees/agent-link" "$2"
  ln -s "$2" "$1/.claude/worktrees/agent-link"
  touch -t 202001010000 "$2"
  touch -h -t 202001010000 "$1/.claude/worktrees/agent-link"
}

@test "groomer --apply --worktrees: a forged worktree entry aimed OUTSIDE .claude/worktrees never deletes the victim" {
  _gx_setup
  # Control: the same forged entry makes plain git delete the victim directory
  _gx_deputy_fixture "$BATS_TEST_TMPDIR/ctl" "$BATS_TEST_TMPDIR/ctl/victim" self
  git -C "$BATS_TEST_TMPDIR/ctl" worktree remove --force -- "$BATS_TEST_TMPDIR/ctl/victim" >/dev/null 2>&1 || true
  [ ! -e "$BATS_TEST_TMPDIR/ctl/victim/keep-me.txt" ]
  _gx_deputy_fixture "$BATS_TEST_TMPDIR/dep" "$BATS_TEST_TMPDIR/dep/victim" self
  run bash "$GROOMER" --apply --worktrees --repo "$BATS_TEST_TMPDIR/dep"
  assert_success
  assert_output --partial "Keeping worktree (not an agent worktree path)"
  [ -e "$BATS_TEST_TMPDIR/dep/victim/keep-me.txt" ]
}

@test "groomer --apply --worktrees: an agent-path worktree whose common dir is ANOTHER repo is kept (identity gate)" {
  _gx_setup
  _gx_deputy_fixture "$BATS_TEST_TMPDIR/ctl" "$BATS_TEST_TMPDIR/ctl/.claude/worktrees/agent-evil" other
  git -C "$BATS_TEST_TMPDIR/ctl" worktree remove --force -- "$BATS_TEST_TMPDIR/ctl/.claude/worktrees/agent-evil" >/dev/null 2>&1 || true
  [ ! -e "$BATS_TEST_TMPDIR/ctl/.claude/worktrees/agent-evil/keep-me.txt" ] # control: plain git deletes it
  _gx_deputy_fixture "$BATS_TEST_TMPDIR/dep" "$BATS_TEST_TMPDIR/dep/.claude/worktrees/agent-evil" other
  run bash "$GROOMER" --apply --worktrees --repo "$BATS_TEST_TMPDIR/dep"
  assert_success
  assert_output --partial "identity mismatch"
  [ -e "$BATS_TEST_TMPDIR/dep/.claude/worktrees/agent-evil/keep-me.txt" ]
}

@test "groomer --apply --worktrees: a symlinked agent-worktree path never deletes the symlink target" {
  _gx_setup
  _gx_symlink_fixture "$BATS_TEST_TMPDIR/ctl" "$BATS_TEST_TMPDIR/ctl-target"
  git -C "$BATS_TEST_TMPDIR/ctl" worktree remove --force -- "$BATS_TEST_TMPDIR/ctl/.claude/worktrees/agent-link" >/dev/null 2>&1 || true
  [ ! -e "$BATS_TEST_TMPDIR/ctl-target/tracked.txt" ] # control: plain git deletes the TARGET's contents
  _gx_symlink_fixture "$BATS_TEST_TMPDIR/dep" "$BATS_TEST_TMPDIR/dep-target"
  run bash "$GROOMER" --apply --worktrees --repo "$BATS_TEST_TMPDIR/dep"
  assert_success
  assert_output --partial "Keeping worktree (not an agent worktree path)"
  [ -e "$BATS_TEST_TMPDIR/dep-target/tracked.txt" ]
  [ -L "$BATS_TEST_TMPDIR/dep/.claude/worktrees/agent-link" ]
}

@test "groomer --apply --worktrees: a real agent worktree holding only UNTRACKED work is kept (control: removed once clean)" {
  _gx_setup
  local wt="$GX_REPO/.claude/worktrees/agent-u"
  git -C "$GX_REPO" worktree add -q "$wt" -b agent-u-branch
  echo "only copy of my work" > "$wt/notes.txt"
  touch -t 202001010000 "$wt"
  git -C "$wt" diff --quiet # control part 1: the tracked-diff check alone cannot see untracked files
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Keeping worktree (uncommitted or untracked files)"
  [ -e "$wt/notes.txt" ]
  rm "$wt/notes.txt" # control part 2: same worktree, nothing untracked -> removed
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ ! -d "$wt" ]
}

@test "groomer --apply --worktrees: age gate removes an OLD clean agent worktree and keeps a fresh one" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-old" -b agent-old-branch
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-fresh" -b agent-fresh-branch
  touch -t 202001010000 "$GX_REPO/.claude/worktrees/agent-old"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp 'Removed worktree: .*/agent-old'
  assert_output --regexp 'Keeping worktree \(recently touched\): .*/agent-fresh'
  [ ! -d "$GX_REPO/.claude/worktrees/agent-old" ]
  [ -d "$GX_REPO/.claude/worktrees/agent-fresh" ]
}

@test "groomer --worktrees: a worktree outside .claude/worktrees/agent-* is kept even when clean and old" {
  _gx_setup
  git -C "$GX_REPO" worktree add -q "$BATS_TEST_TMPDIR/plain-wt" -b plain-wt-branch
  touch -t 202001010000 "$BATS_TEST_TMPDIR/plain-wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp 'Keeping worktree \(not an agent worktree path\): .*/plain-wt'
  [ -d "$BATS_TEST_TMPDIR/plain-wt" ]
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

# ---------------------------------------------------------------------------
# U2c (2026-10-04): quarantine-by-rename TOCTOU defence for `--apply --worktrees`.
# All victims live under BATS_TEST_TMPDIR. Swap tests run an injected script COPY: a hook line is
# inserted immediately before the rename step, so the swap lands AFTER every gate has passed.
# ---------------------------------------------------------------------------
_gq_copy() { # [nocheck]  -> $GQ_S = path of the injected groomer copy
  local s="$BATS_TEST_TMPDIR/s"
  mkdir -p "$s"
  cp "$REPO_DIR/scripts/cast-hook-lib.sh" "$REPO_DIR/scripts/cast_groom_fs.py" "$REPO_DIR/scripts/cast_guard.py" "$s/"
  awk '/^      if ! _rename_path "\$wt_path" "\$qdir\/\$wt_name"; then$/ { print "      eval \"${GQ_SWAP:-:}\"" } { print }' \
    "$GROOMER" >"$s/groomer.sh"
  grep -q 'GQ_SWAP' "$s/groomer.sh" # the hook line really landed (else the swap tests are vacuous)
  if [ "${1:-}" = "nocheck" ]; then
    sed -i.bak 's/^      if \[\[ -z "\$wt_moved_id" \]\] || \[\[ "\$wt_moved_id" != "\$wt_id" \]\]; then$/      if false; then/' "$s/groomer.sh"
    rm -f "$s/groomer.sh.bak"
    grep -q '^      if false; then$' "$s/groomer.sh" # the mutation really applied
  fi
  GQ_S="$s/groomer.sh"
}
_gq_wt() { # name [branch-suffix] -> creates an old clean agent worktree $GX_REPO/.claude/worktrees/<name>
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/$1" -b "$1-branch${2:-}"
  touch -t 202001010000 "$GX_REPO/.claude/worktrees/$1"
}
_gq_victim() { # dir -> real directory with one file (the thing that must survive)
  mkdir -p "$1"
  echo precious >"$1/precious.txt"
}

@test "groomer quarantine: leaf swapped to a SYMLINK after the gates never deletes the victim" {
  _gx_setup
  _gq_wt agent-x
  _gq_victim "$BATS_TEST_TMPDIR/victim"
  _gq_copy
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  run env GQ_SWAP="rm -rf '$wt' && ln -s '$BATS_TEST_TMPDIR/victim' '$wt' && echo swapped >'$BATS_TEST_TMPDIR/swap-landed' && [ -L '$wt' ]" \
    bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ -e "$BATS_TEST_TMPDIR/swap-landed" ] # control: the swap really happened (path became a symlink to the victim)
  [ -e "$BATS_TEST_TMPDIR/victim/precious.txt" ]
  refute_output --partial "Removed worktree"
  assert_output --partial "WARN"
}

@test "groomer quarantine: leaf swapped to a DIFFERENT real dir is restored, not deleted (control: no identity check deletes it)" {
  _gx_setup
  _gq_wt agent-x
  _gq_victim "$BATS_TEST_TMPDIR/victim"
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  local swap="mv '$wt' '$BATS_TEST_TMPDIR/orig-wt' && mv '$BATS_TEST_TMPDIR/victim' '$wt'"
  _gq_copy nocheck
  run env GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ ! -e "$wt/precious.txt" ] # control: with the identity check removed the victim IS deleted
  # reset, then run the unmutated script copy
  rm -rf "$HOME/.claude/groomer-quarantine" "$wt" "$BATS_TEST_TMPDIR/orig-wt"
  git -C "$GX_REPO" worktree prune
  _gq_wt agent-x 2
  _gq_victim "$BATS_TEST_TMPDIR/victim"
  _gq_copy
  run env GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ -e "$wt/precious.txt" ] # restored to the original path, intact
  assert_output --partial "swap detected"
  refute_output --partial "Removed worktree"
}

@test "groomer quarantine: PARENT .claude/worktrees swapped to a symlink never deletes the victim (control: no identity check deletes it)" {
  _gx_setup
  _gq_wt agent-x
  local wts="$GX_REPO/.claude/worktrees"
  local swap="mv '$wts' '$BATS_TEST_TMPDIR/orig-wts' && ln -s '$BATS_TEST_TMPDIR/vparent' '$wts'"
  _gq_victim "$BATS_TEST_TMPDIR/vparent/agent-x"
  _gq_copy nocheck
  run env GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/vparent/agent-x/precious.txt" ] # control: swap real + check removed -> victim deleted
  # reset, then run the unmutated script copy
  rm -rf "$HOME/.claude/groomer-quarantine"
  rm -f "$wts"
  rm -rf "$BATS_TEST_TMPDIR/orig-wts" "$BATS_TEST_TMPDIR/vparent"
  git -C "$GX_REPO" worktree prune
  _gq_wt agent-x 2
  _gq_victim "$BATS_TEST_TMPDIR/vparent/agent-x"
  _gq_copy
  run env GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ -e "$BATS_TEST_TMPDIR/vparent/agent-x/precious.txt" ]
  assert_output --partial "swap detected"
  refute_output --partial "Removed worktree"
}

@test "groomer --apply --worktrees: a LOCKED agent worktree is kept (control: unlocked twin removed)" {
  _gx_setup
  _gq_wt agent-x
  _gq_wt agent-y
  git -C "$GX_REPO" worktree lock "$GX_REPO/.claude/worktrees/agent-x"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp "Keeping worktree \(locked\): .*/\.claude/worktrees/agent-x"
  [ -d "$GX_REPO/.claude/worktrees/agent-x" ]
  [ ! -d "$GX_REPO/.claude/worktrees/agent-y" ] # control
  assert_output --regexp "Removed worktree: .*/\.claude/worktrees/agent-y"
}

_gq_ignore_repo() { # commit a .gitignore covering the rebuildable and the non-rebuildable cases
  printf '%s\n' '*.env' '.env.local' 'node_modules/' '__pycache__/' '*.pyc' >"$GX_REPO/.gitignore"
  git -C "$GX_REPO" add .gitignore
  git -C "$GX_REPO" commit -q -m ignore
}

@test "groomer --apply --worktrees: a worktree with only REBUILDABLE ignored files (__pycache__, node_modules) is removed" {
  _gx_setup
  _gq_ignore_repo
  _gq_wt agent-x
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  mkdir -p "$wt/__pycache__" "$wt/node_modules/a"
  echo b >"$wt/__pycache__/x.pyc"
  echo b >"$wt/node_modules/a/b.js"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp "Removed worktree: .*/agent-x"
  [ ! -d "$wt" ]
}

@test "groomer --apply --worktrees: an ignored x.env keeps the worktree and is named (control: removed once deleted)" {
  _gx_setup
  _gq_ignore_repo
  _gq_wt agent-x
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  echo SECRET=1 >"$wt/x.env"
  touch -t 202001010000 "$wt"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] # control: plain status looks clean
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Keeping worktree (ignored files not in the rebuildable list)"
  assert_output --partial "x.env"
  [ -e "$wt/x.env" ]
  rm "$wt/x.env"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ ! -d "$wt" ]
}

@test "groomer --apply --worktrees: MIXED ignored (__pycache__ + .env.local) keeps the worktree" {
  _gx_setup
  _gq_ignore_repo
  _gq_wt agent-x
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  mkdir -p "$wt/__pycache__"
  echo b >"$wt/__pycache__/x.pyc"
  echo SECRET=1 >"$wt/.env.local"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Keeping worktree (ignored files not in the rebuildable list)"
  assert_output --partial ".env.local"
  [ -e "$wt/.env.local" ]
}

@test "groomer --apply --worktrees: an ignored file UNDER a non-ignored build/ dir (build/secrets.env) keeps the worktree (control: removed once deleted)" {
  _gx_setup
  printf '%s\n' '*.env' >"$GX_REPO/.gitignore"
  git -C "$GX_REPO" add .gitignore
  git -C "$GX_REPO" commit -q -m ignore
  _gq_wt agent-x
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  mkdir -p "$wt/build"
  echo SECRET=1 >"$wt/build/secrets.env"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Keeping worktree (ignored files not in the rebuildable list)"
  assert_output --partial "build/secrets.env"
  [ -e "$wt/build/secrets.env" ]
  rm "$wt/build/secrets.env"
  rmdir "$wt/build"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ ! -d "$wt" ]
}

@test "groomer --apply --worktrees: a NESTED wholly-ignored pkg/node_modules/ is still removed" {
  _gx_setup
  _gq_ignore_repo
  _gq_wt agent-x
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  mkdir -p "$wt/pkg/node_modules/a"
  echo b >"$wt/pkg/node_modules/a/b.js"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp "Removed worktree: .*/agent-x"
  [ ! -d "$wt" ]
}

_gq_copy_del() { # [nopin] -> injected copy with the hook line just before the quarantine delete
  local s="$BATS_TEST_TMPDIR/s"
  mkdir -p "$s"
  cp "$REPO_DIR/scripts/cast-hook-lib.sh" "$REPO_DIR/scripts/cast_groom_fs.py" "$REPO_DIR/scripts/cast_guard.py" "$s/"
  awk '/^      if _quarantine_delete "\$qdir" "\$wt_name"; then$/ { print "      eval \"${GQ_SWAP:-:}\"" } { print }' \
    "$GROOMER" >"$s/groomer.sh"
  grep -q 'GQ_SWAP' "$s/groomer.sh" # the hook line really landed
  if [ "${1:-}" = "nopin" ]; then
    sed -i.bak '/^    \[\[ "\$(pwd -P)" == "\$GROOM_QROOT_REAL\/\$base" \]\] || exit 1$/d' "$s/groomer.sh"
    rm -f "$s/groomer.sh.bak"
    # the pwd-check mutation really applied (match the check LINE only: the pinned delete on the next
    # line also names $GROOM_QROOT_REAL/$base, so a bare path pattern matches it and never proves the deletion)
    run grep -qF '[[ "$(pwd -P)" == "$GROOM_QROOT_REAL/$base" ]]' "$s/groomer.sh"
    assert_failure 1
    # ...and revert the delete to the pre-U2c-pin cwd-relative rm (the pinned primitive is a 2nd layer)
    sed -i.bak 's#^    python3 -I "\$_GROOM_FS" rmtree-pinned "\$GROOM_QROOT_REAL/\$base" "\$name" "\$GROOM_QROOT_REAL" || exit 1$#    rm -rf -- "./$name" || exit 1#' "$s/groomer.sh"
    rm -f "$s/groomer.sh.bak"
    if grep -qF 'rmtree-pinned "$GROOM_QROOT_REAL' "$s/groomer.sh"; then return 1; fi # that mutation really applied
  fi
  GQ_S="$s/groomer.sh"
}

@test "groomer --apply --worktrees: a planted symlinked .git/worktrees/<id> is NEVER followed by registry cleanup (control: plain prune empties its victim)" {
  _gx_setup
  # control: plain git DOES delete the symlink target on prune (the exact C1 reproduction)
  git init -q --initial-branch=main "$BATS_TEST_TMPDIR/ctl"
  mkdir -p "$BATS_TEST_TMPDIR/ctl/.git/worktrees" "$BATS_TEST_TMPDIR/vctl/sub"
  echo precious >"$BATS_TEST_TMPDIR/vctl/sub/f.txt"
  ln -s "$BATS_TEST_TMPDIR/vctl" "$BATS_TEST_TMPDIR/ctl/.git/worktrees/zz"
  git -C "$BATS_TEST_TMPDIR/ctl" worktree prune >/dev/null 2>&1 || true
  [ ! -e "$BATS_TEST_TMPDIR/vctl/sub/f.txt" ]
  # real run
  _gq_wt agent-x
  mkdir -p "$BATS_TEST_TMPDIR/vprune/sub"
  echo precious >"$BATS_TEST_TMPDIR/vprune/sub/f.txt"
  echo precious2 >"$BATS_TEST_TMPDIR/vprune/top.txt"
  ln -s "$BATS_TEST_TMPDIR/vprune" "$GX_REPO/.git/worktrees/zz"
  [ -e "$GX_REPO/.git/worktrees/agent-x" ]
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp "Removed worktree: .*/agent-x"
  [ ! -d "$GX_REPO/.claude/worktrees/agent-x" ]
  [ ! -e "$GX_REPO/.git/worktrees/agent-x" ] # its own registry entry is gone
  [ -e "$BATS_TEST_TMPDIR/vprune/sub/f.txt" ]
  [ -e "$BATS_TEST_TMPDIR/vprune/top.txt" ]
  [ -L "$GX_REPO/.git/worktrees/zz" ]
}

@test "groomer quarantine: the quarantine dir swapped to a symlink just before the delete never deletes the victim (control: no pinned-cwd check and no pinned delete deletes it)" {
  _gx_setup
  _gq_wt agent-x
  mkdir -p "$BATS_TEST_TMPDIR/victim/agent-x"
  echo precious >"$BATS_TEST_TMPDIR/victim/agent-x/p.txt"
  local swap='mv "$qdir" "$qdir.orig" && ln -s "'"$BATS_TEST_TMPDIR"'/victim" "$qdir"'
  _gq_copy_del nopin
  run env GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/victim/agent-x/p.txt" ] # control: swap real + pin removed -> victim deleted
  # reset, then the unmutated copy
  rm -rf "$HOME/.claude/groomer-quarantine"
  rm -rf "$GX_REPO/.claude/worktrees/agent-x"
  git -C "$GX_REPO" worktree prune
  _gq_wt agent-x 2
  mkdir -p "$BATS_TEST_TMPDIR/victim/agent-x"
  echo precious >"$BATS_TEST_TMPDIR/victim/agent-x/p.txt"
  _gq_copy_del
  run env GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ -e "$BATS_TEST_TMPDIR/victim/agent-x/p.txt" ]
  assert_output --partial "could not fully delete"
  refute_output --partial "Removed worktree"
}

_gq_copy_reg() { # [plain] -> injected copy with the hook line just before the registry delete
  local s="$BATS_TEST_TMPDIR/s"
  mkdir -p "$s"
  cp "$REPO_DIR/scripts/cast-hook-lib.sh" "$REPO_DIR/scripts/cast_groom_fs.py" "$REPO_DIR/scripts/cast_guard.py" "$s/"
  awk '/^  python3 -I "\$_GROOM_FS" rmtree-pinned "\$reg" "\$name" "\$reg" 2>\/dev\/null$/ { print "  eval \"${GQ_SWAP:-:}\"" } { print }' \
    "$GROOMER" >"$s/groomer.sh"
  grep -q 'GQ_SWAP' "$s/groomer.sh" # the hook line really landed
  if [ "${1:-}" = "plain" ]; then
    # control: the pre-pin absolute-path delete (re-resolves .git/worktrees at delete time)
    sed -i.bak 's#^  python3 -I "\$_GROOM_FS" rmtree-pinned "\$reg" "\$name" "\$reg" 2>/dev/null$#  rm -rf -- "$reg/$name"#' "$s/groomer.sh"
    rm -f "$s/groomer.sh.bak"
    if grep -qF 'rmtree-pinned "$reg"' "$s/groomer.sh"; then return 1; fi # the mutation really applied
  fi
  GQ_S="$s/groomer.sh"
}

@test "groomer registry cleanup: .git/worktrees swapped to a symlink just before the delete never deletes the victim (control: absolute-path delete does)" {
  _gx_setup
  _gq_wt agent-x
  mkdir -p "$BATS_TEST_TMPDIR/vreg/agent-x"
  echo precious >"$BATS_TEST_TMPDIR/vreg/agent-x/p.txt"
  local swap='mv "$GX_REPO/.git/worktrees" "$GX_REPO/.git/worktrees.orig" && ln -s "'"$BATS_TEST_TMPDIR"'/vreg" "$GX_REPO/.git/worktrees"'
  _gq_copy_reg plain
  run env GX_REPO="$GX_REPO" GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/vreg/agent-x/p.txt" ] # control: swap real + absolute-path delete -> victim deleted
  # reset, then the real (pinned) copy
  rm -rf "$HOME/.claude/groomer-quarantine"
  rm -f "$GX_REPO/.git/worktrees"
  mv "$GX_REPO/.git/worktrees.orig" "$GX_REPO/.git/worktrees"
  rm -rf "$GX_REPO/.claude/worktrees/agent-x"
  git -C "$GX_REPO" worktree prune
  _gq_wt agent-x 2
  mkdir -p "$BATS_TEST_TMPDIR/vreg/agent-x"
  echo precious >"$BATS_TEST_TMPDIR/vreg/agent-x/p.txt"
  _gq_copy_reg
  run env GX_REPO="$GX_REPO" GQ_SWAP="$swap" bash "$GQ_S" --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ -e "$BATS_TEST_TMPDIR/vreg/agent-x/p.txt" ]
  assert_output --partial "registry entry not removed"
}

@test "cast_groom_fs.py rmtree-pinned: deletes PARENT/NAME only for a canonical in-radius PARENT; every refusal exits 1 with empty stdout and no traceback" {
  local h="$REPO_DIR/scripts/cast_groom_fs.py" r d
  r="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/rp"
  d="$r/par"
  mkdir -p "$d/gone/sub" "$d/keep" "$BATS_TEST_TMPDIR/outside/gone"
  echo x >"$d/gone/sub/f"
  echo precious >"$BATS_TEST_TMPDIR/outside/gone/p"
  ln -s "$d" "$r/plink"
  ln -s "$BATS_TEST_TMPDIR/outside" "$d/escape"
  # refusals: nothing deleted, nothing on stdout, no traceback
  for args in "$d .. $r" "$d a/b $r" "$d keep/../gone $r" "$r/plink gone $r" "$BATS_TEST_TMPDIR/outside gone $r" "$d escape $r" "$d missing $r" "$d gone"; do
    # shellcheck disable=SC2086
    run --separate-stderr python3 -I "$h" rmtree-pinned $args
    assert_failure
    [ -z "$output" ]
    [[ "$stderr" != *Traceback* ]]
  done
  [ -e "$d/gone/sub/f" ]
  [ -e "$d/keep" ]
  [ -e "$BATS_TEST_TMPDIR/outside/gone/p" ]
  [ -L "$d/escape" ]
  # success
  run --separate-stderr python3 -I "$h" rmtree-pinned "$d" gone "$r"
  assert_success
  [ -z "$output" ]
  [ ! -e "$d/gone" ]
  [ -d "$d/keep" ]
  [ -e "$BATS_TEST_TMPDIR/outside/gone/p" ]
  # a missing/broken cast_guard.py next to the helper -> exit 1, no traceback, no delete
  local s="$BATS_TEST_TMPDIR/hs"
  mkdir -p "$s" "$d/gone2"
  cp "$h" "$s/"
  run --separate-stderr python3 -I "$s/cast_groom_fs.py" rmtree-pinned "$d" gone2 "$r"
  assert_failure
  [ -z "$output" ]
  [[ "$stderr" != *Traceback* ]]
  [ -d "$d/gone2" ]
  echo 'raise SystemError("broken")' >"$s/cast_guard.py"
  run --separate-stderr python3 -I "$s/cast_groom_fs.py" rmtree-pinned "$d" gone2 "$r"
  assert_failure
  [ -z "$output" ]
  [[ "$stderr" != *Traceback* ]]
  [ -d "$d/gone2" ]
}

@test "groomer --apply --worktrees: an ignored FILE named build is kept; an ignored build/ DIRECTORY is removed" {
  _gx_setup
  printf '%s\n' 'build' >"$GX_REPO/.gitignore"
  git -C "$GX_REPO" add .gitignore
  git -C "$GX_REPO" commit -q -m ignore
  _gq_wt agent-x
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  echo SECRET=1 >"$wt/build"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Keeping worktree (ignored files not in the rebuildable list)"
  [ -e "$wt/build" ]
  rm "$wt/build"
  mkdir -p "$wt/build"
  echo out >"$wt/build/o.js"
  touch -t 202001010000 "$wt"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ ! -d "$wt" ]
}

@test "groomer --apply --worktrees: a group/world-writable quarantine root is tightened to 700 before use" {
  _gx_setup
  _gq_wt agent-x
  mkdir -p "$HOME/.claude/groomer-quarantine"
  chmod 777 "$HOME/.claude/groomer-quarantine"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ "$(ls -ld "$HOME/.claude/groomer-quarantine" | cut -c1-10)" = "drwx------" ]
}

@test "groomer: invoked by a RELATIVE path it never runs a helper planted inside the target repo (control: relative resolution would)" {
  _gx_setup
  _gq_wt agent-x
  local inst="$BATS_TEST_TMPDIR/inst"
  mkdir -p "$inst" "$GX_REPO/inst"
  cp "$GROOMER" "$REPO_DIR/scripts/cast-hook-lib.sh" "$REPO_DIR/scripts/cast_groom_fs.py" "$REPO_DIR/scripts/cast_guard.py" "$inst/"
  printf '%s\n' 'import sys' "open('$BATS_TEST_TMPDIR/planted-ran','w').close()" 'sys.exit(0)' >"$GX_REPO/inst/cast_groom_fs.py"
  cp "$REPO_DIR/scripts/cast-hook-lib.sh" "$GX_REPO/inst/"
  cd "$BATS_TEST_TMPDIR"
  run bash inst/cast-branch-groomer.sh --apply --worktrees --repo "$GX_REPO"
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/planted-ran" ]
  assert_output --regexp "Removed worktree: .*/agent-x" # the REAL helper did the work
  # control: the relative form really would resolve to the planted helper from inside the repo
  (cd "$GX_REPO" && [ "$(dirname inst/cast-branch-groomer.sh)/cast_groom_fs.py" = "inst/cast_groom_fs.py" ] && python3 -I inst/cast_groom_fs.py)
  [ -e "$BATS_TEST_TMPDIR/planted-ran" ]
}

@test "groomer: a missing cast_groom_fs.py helper makes it refuse to run (non-zero) and delete nothing" {
  _gx_setup
  _gq_wt agent-x
  local s="$BATS_TEST_TMPDIR/s"
  mkdir -p "$s"
  cp "$REPO_DIR/scripts/cast-hook-lib.sh" "$GROOMER" "$s/" # deliberately NOT the helper
  run bash "$s/cast-branch-groomer.sh" --apply --worktrees --repo "$GX_REPO"
  assert_failure
  assert_output --partial "cannot read helper"
  [ -d "$GX_REPO/.claude/worktrees/agent-x" ]
}

@test "cast_groom_fs.py: identity/rename/root-ok semantics; bad usage exits 1 with no traceback" {
  local h="$REPO_DIR/scripts/cast_groom_fs.py" d="$BATS_TEST_TMPDIR/fs"
  mkdir -p "$d/real"
  ln -s "$d/real" "$d/link"
  : >"$d/file"
  run python3 -I "$h" identity "$d/real"
  assert_success
  assert_output --regexp '^[0-9]+:[0-9]+$'
  run python3 -I "$h" identity "$d/link"
  assert_failure
  assert_output ""
  run python3 -I "$h" identity "$d/file"
  assert_failure
  run python3 -I "$h" identity "$d/missing"
  assert_failure
  assert_output ""
  run python3 -I "$h" rename "$d/file" "$d/file2"
  assert_success
  [ -e "$d/file2" ]
  [ ! -e "$d/file" ]
  run python3 -I "$h" rename "$d/missing" "$d/x"
  assert_failure
  chmod 700 "$d/real"
  run python3 -I "$h" root-ok "$d/real"
  assert_success
  chmod 770 "$d/real"
  run python3 -I "$h" root-ok "$d/real"
  assert_failure
  run python3 -I "$h" root-ok "$d/link"
  assert_failure
  run python3 -I "$h" bogus x
  assert_failure
  assert_output ""
  run python3 -I "$h"
  assert_failure
  assert_output ""
}

@test "groomer --worktrees: an old KEPT worktree is reported STALE and counted; a leftover quarantine dir WARNs and is NOT removed" {
  _gx_setup
  _gq_wt agent-x
  local wt="$GX_REPO/.claude/worktrees/agent-x"
  echo mine >"$wt/notes.txt"
  touch -t 202001010000 "$wt"
  mkdir -p "$HOME/.claude/groomer-quarantine/wt.PLANTED"
  echo keep >"$HOME/.claude/groomer-quarantine/wt.PLANTED/f"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp "STALE \(kept >30d, review manually\): .*/agent-x"
  assert_output --partial "1 agent worktrees kept"
  assert_output --partial "WARN: 1 leftover quarantine dir(s)"
  [ -e "$HOME/.claude/groomer-quarantine/wt.PLANTED/f" ]
  [ -e "$wt/notes.txt" ]
}

@test "groomer --apply --worktrees: successful removal leaves no quarantine dir and drops the registry entry" {
  _gx_setup
  _gq_wt agent-x
  git -C "$GX_REPO" worktree list | grep -q agent-x # control: registered before
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --regexp "Removed worktree: .*/\.claude/worktrees/agent-x"
  [ -d "$HOME/.claude/groomer-quarantine" ]
  [ -z "$(find "$HOME/.claude/groomer-quarantine" -mindepth 1 2>/dev/null)" ]
  run git -C "$GX_REPO" worktree list
  assert_success
  refute_output --partial agent-x
  [ ! -e "$GX_REPO/.git/worktrees/agent-x" ]
}

@test "groomer --apply --worktrees: a SYMLINKED quarantine root removes nothing and warns" {
  _gx_setup
  _gq_wt agent-x
  mkdir -p "$HOME/.claude" "$BATS_TEST_TMPDIR/qtarget"
  ln -s "$BATS_TEST_TMPDIR/qtarget" "$HOME/.claude/groomer-quarantine"
  run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "WARN: quarantine root unusable"
  refute_output --partial "Removed worktree"
  [ -d "$GX_REPO/.claude/worktrees/agent-x" ]
  [ -z "$(find "$BATS_TEST_TMPDIR/qtarget" -mindepth 1 2>/dev/null)" ]
}

# S3b-D (2026-10-07): the groomer runs under launchd with an unpinned PATH and resolved python3 /
# mktemp by NAME. PATH is now pinned to the system dirs, so a python3/mktemp planted earlier on PATH
# never runs (the control: the same shims DO fire when invoked through that PATH directly).
@test "groomer S3b-D: a python3/mktemp planted first on PATH never runs (control: the shims fire when PATH is used)" {
  _gx_setup
  local shim="$BATS_TEST_TMPDIR/evilbin" tool
  mkdir -p "$shim"
  for tool in python3 mktemp; do
    printf '#!/bin/sh\ntouch "%s/fired-path-%s"\nexit 99\n' "$GX_MARK" "$tool" > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  # CONTROL: with this PATH the shims are what `python3`/`mktemp` resolve to
  PATH="$shim:$PATH" run bash -c 'python3 -c pass; mktemp'
  [ "$(_gx_fired)" -eq 2 ]
  rm -f "$GX_MARK"/fired-*
  git -C "$GX_REPO" worktree add -q "$GX_REPO/.claude/worktrees/agent-pin" -b pin-branch
  touch -t 202001010000 "$GX_REPO/.claude/worktrees/agent-pin"
  PATH="$shim:$PATH" run bash "$GROOMER" --apply --worktrees --repo "$GX_REPO"
  assert_success
  assert_output --partial "Removed worktree"
  [ "$(_gx_fired)" -eq 0 ]
  [ ! -d "$GX_REPO/.claude/worktrees/agent-pin" ]
}
