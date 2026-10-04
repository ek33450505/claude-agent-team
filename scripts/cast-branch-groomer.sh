#!/usr/bin/env bash
# cast-branch-groomer.sh — Prune stale branches and dead worktrees
#
# Default mode: --dry-run (print what would be deleted, change nothing).
# Use --apply to actually delete.
#
# Branch deletion policy:
#   worktree-agent-*: committerdate < now-7d
#   feature/* fix/* : merged into main AND remote tracking ref is gone ([gone])
#
# Hard whitelist (never deleted):
#   main, feat/*, feature/cast-v7-*, any branch checked out in a worktree
#
# Usage:
#   bash scripts/cast-branch-groomer.sh [--dry-run] [--apply] [--worktrees] [--repo <path>]

set -euo pipefail

# ── Subprocess guard ──────────────────────────────────────────────────────
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

# _log_error: never fails, appends to hook-errors.log
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { printf '[%s] ERROR %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$0" "$1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

# ── Parse flags ───────────────────────────────────────────────────────────
DRY_RUN=1
DO_WORKTREES=0
REPO_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --apply)     DRY_RUN=0 ;;
    --worktrees) DO_WORKTREES=1 ;;
    --repo)      REPO_DIR="$2"; shift ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      printf '[cast-branch-groomer] Unknown flag: %s\n' "$1" >&2
      ;;
  esac
  shift
done

# ── Hostile-repo hardening ───────────────────────────────────────────────
# Runs unattended (launchd), OUTSIDE the Bash sandbox, over repos/worktrees an agent can
# write to. Repo-local config an agent plants can make git exec programs (fsmonitor, filter
# drivers, hooks incl. git>=2.54 config hooks, gpg, promisor lazy fetch). EVERY git call below
# goes through cast_git_safe (scripts/cast-hook-lib.sh) -- see its header for the contract.
# rc 2/3/126 (helper could not run git) are errors like any other: they must mean "keep".
# If the lib cannot be loaded we refuse to run ANY git (a failing job beats bare git).
# unset first: an inherited _CAST_HOOK_LIB_LOADED makes the lib skip its definitions, and an
# inherited exported function must not stand in for the real one.
# Resolve this script's directory ONCE, absolutely, before anything uses it and before the `cd` into
# --repo below: a relative $0 would otherwise resolve the lib/helper against the (agent-controlled)
# repo and run its copy unsandboxed.
if ! _GROOM_DIR="$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)" || [[ -z "$_GROOM_DIR" ]]; then
  printf '[cast-branch-groomer] ERROR: cannot resolve script directory from %s; refusing to run\n' "$0" >&2
  _log_error "cannot resolve script directory from $0"
  exit 1
fi
_GROOM_LIB="$_GROOM_DIR/cast-hook-lib.sh"
unset -f cast_git_safe 2>/dev/null || true
unset _CAST_HOOK_LIB_LOADED
# shellcheck source=cast-hook-lib.sh
# (-r first: bash 3.2 exits the shell silently on a failed `source` of a missing file.)
if [[ ! -r "$_GROOM_LIB" ]] || ! source "$_GROOM_LIB" 2>/dev/null || ! declare -F cast_git_safe >/dev/null 2>&1; then
  printf '[cast-branch-groomer] ERROR: cannot load cast_git_safe from %s; refusing to run git\n' "$_GROOM_LIB" >&2
  _log_error "cannot load cast_git_safe from $_GROOM_LIB"
  exit 1
fi

# Filesystem primitives (lstat identity, rename(2)-only move, quarantine-root check) live in a helper
# next to this script. Without it the quarantine delete cannot be done safely: refuse to run at all.
_GROOM_FS="$_GROOM_DIR/cast_groom_fs.py"
if [[ ! -f "$_GROOM_FS" ]] || [[ ! -r "$_GROOM_FS" ]]; then
  printf '[cast-branch-groomer] ERROR: cannot read helper %s; refusing to run\n' "$_GROOM_FS" >&2
  _log_error "cannot read helper $_GROOM_FS"
  exit 1
fi

# If --repo was given, cd into it so git commands operate there
if [[ -n "$REPO_DIR" ]]; then
  if [[ ! -d "$REPO_DIR" ]]; then
    printf '[cast-branch-groomer] ERROR: --repo path not found: %s\n' "$REPO_DIR" >&2
    exit 1
  fi
  cd "$REPO_DIR"
fi
GROOM_REPO="$(pwd -P)"

# Verify we're in a git repo
_rc=0
cast_git_safe "$GROOM_REPO" rev-parse --git-dir &>/dev/null || _rc=$?
case "$_rc" in
  0) ;;
  2 | 3 | 126)
    printf '[cast-branch-groomer] ERROR: git hardening could not be established (rc=%s); refusing to run git\n' "$_rc" >&2
    _log_error "git hardening could not be established (rc=$_rc) in $GROOM_REPO"
    exit 1
    ;;
  *)
    printf '[cast-branch-groomer] ERROR: not a git repository\n' >&2
    exit 1
    ;;
esac

# ── Build whitelist: currently checked-out branches ───────────────────────
# Fail CLOSED: an unreadable worktree list would silently empty the whitelist.
if ! _wt_porcelain="$(cast_git_safe "$GROOM_REPO" worktree list --porcelain 2>/dev/null)"; then
  printf '[cast-branch-groomer] ERROR: could not list worktrees; refusing to groom\n' >&2
  exit 1
fi
CHECKED_OUT_BRANCHES=()
while IFS= read -r line; do
  # git worktree list --porcelain emits "branch refs/heads/<name>"
  branch="${line#branch refs/heads/}"
  if [[ -n "$branch" ]]; then
    CHECKED_OUT_BRANCHES+=("$branch")
  fi
done < <(printf '%s\n' "$_wt_porcelain" | grep '^branch' || true)

_is_whitelisted() {
  local b="$1"
  # Hard-coded protected patterns
  [[ "$b" == "main" ]]     && return 0
  [[ "$b" == "master" ]]   && return 0
  [[ "$b" == HEAD* ]]      && return 0
  [[ "$b" =~ ^feat/ ]]     && return 0
  [[ "$b" =~ ^feature/cast-v7- ]] && return 0
  # Currently checked out in any worktree
  for co in "${CHECKED_OUT_BRANCHES[@]+"${CHECKED_OUT_BRANCHES[@]}"}"; do
    [[ "$b" == "$co" ]] && return 0
  done
  return 1
}

# (Removed: a best-effort `gh pr list` + _has_open_pr. Nothing ever called _has_open_pr, and gh
# shells out to bare git in the repo cwd -- unhardened, outside cast_git_safe.)

# ── Date helpers ─────────────────────────────────────────────────────────
_epoch_now() { date +%s; }
_days_since_commit() {
  local branch="$1"
  local ref_out commit_epoch now
  # Plumbing (for-each-ref) instead of `git log`: log honours log.showSignature/gpg.program.
  # Pattern also matches refs/heads/<branch>/..., so keep only the exact ref.
  # FAIL-SAFE: any git error or missing/garbled epoch -> age UNKNOWN -> report 0 days (fresh), so the
  # caller KEEPS the branch. (A fallback epoch of 0 would read as ~20000 days old = delete.)
  if ! ref_out="$(cast_git_safe "$GROOM_REPO" for-each-ref \
    --format='%(refname) %(committerdate:unix)' "refs/heads/$branch" 2>/dev/null)"; then
    echo 0
    return 0
  fi
  commit_epoch="$(printf '%s\n' "$ref_out" | awk -v r="refs/heads/$branch" '$1 == r { print $2; exit }')"
  if [[ ! "$commit_epoch" =~ ^[0-9]+$ ]]; then
    echo 0
    return 0
  fi
  now=$(_epoch_now)
  echo $(((now - commit_epoch) / 86400))
}

# _is_content_merged <branch> — 0 if every commit on <branch> is already on main
# (true/ff merge OR squash merge), 1 otherwise. FAIL-SAFE: any git error -> 1 (not merged).
_is_content_merged() {
  local branch="$1"
  local ahead_count plus_count cherry_total cherry_out
  ahead_count="$(cast_git_safe "$GROOM_REPO" rev-list --count "main..$branch" 2>/dev/null || echo 1)"
  if [[ "$ahead_count" -eq 0 ]]; then
    return 0
  fi
  # ONE cherry call, status checked: two calls (one for '+' lines, one for the total) let a
  # transient error in the first read as "no '+' lines" while the second succeeds = a false
  # "merged" on an unmerged branch. Empty output also means "cannot prove merged".
  cherry_out="$(cast_git_safe "$GROOM_REPO" cherry main "$branch" 2>/dev/null)" || return 1
  [[ -n "$cherry_out" ]] || return 1
  plus_count=$(printf '%s\n' "$cherry_out" | grep -c '^+' || true)
  cherry_total=$(printf '%s\n' "$cherry_out" | grep -c '' || true)
  if [[ "$plus_count" -eq 0 ]] && [[ "$cherry_total" -gt 0 ]] && [[ "$cherry_total" -eq "$ahead_count" ]]; then
    return 0
  fi
  return 1
}

# ── Deletion trackers ────────────────────────────────────────────────────
DELETED_WORKTREE_AGENT=0
DELETED_MERGED=0
WARN_COUNT=0

_delete_branch() {
  local branch="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] Would delete branch: %s\n' "$branch"
  else
    # `--`: a ref named like an option must never be parsed as one. -d then -D is deliberate
    # (squash merges; gated by _is_content_merged).
    if cast_git_safe "$GROOM_REPO" branch -d -- "$branch" 2>/dev/null ||
      cast_git_safe "$GROOM_REPO" branch -D -- "$branch" 2>/dev/null; then
      printf '[groomer] Deleted branch: %s\n' "$branch"
    else
      printf '[groomer] WARN: could not delete branch: %s\n' "$branch" >&2
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  fi
}

# ── Process worktree-agent-* branches (>7d) ───────────────────────────────
while IFS= read -r branch; do
  branch="$(printf '%s' "$branch" | sed 's/^[* ]*//')"
  [[ -z "$branch" ]] && continue
  [[ "$branch" != worktree-agent-* ]] && continue
  _is_whitelisted "$branch" && continue
  local_age=$(_days_since_commit "$branch")
  if [[ "$local_age" -ge 7 ]]; then
    _delete_branch "$branch"
    DELETED_WORKTREE_AGENT=$((DELETED_WORKTREE_AGENT + 1))
  fi
done < <(cast_git_safe "$GROOM_REPO" branch --list 'worktree-agent-*' 2>/dev/null || true)

# ── Process feature/* and fix/* — merged + [gone] remote ─────────────────
while IFS= read -r vv_line; do
  # git branch -vv output: "  branch-name  <hash> [origin/branch: gone] message"
  if [[ "$vv_line" =~ \[.*gone\] ]]; then
    branch="$(printf '%s' "$vv_line" | awk '{print $1}' | sed 's/^\*//')"
    [[ -z "$branch" ]] && continue
    if [[ "$branch" =~ ^feature/ ]] || [[ "$branch" =~ ^fix/ ]]; then
      _is_whitelisted "$branch" && continue
      if _is_content_merged "$branch"; then
        _delete_branch "$branch"
        DELETED_MERGED=$((DELETED_MERGED + 1))
      fi
    fi
  fi
done < <(cast_git_safe "$GROOM_REPO" branch -vv 2>/dev/null || true)

# ── Worktree directory pruning (--worktrees flag) ─────────────────────────
DELETED_WORKTREES=0

# Ignored entries that may be deleted along with a worktree: every one is REGENERABLE by tooling
# (never user data). A path is rebuildable iff its LAST component equals one of these, or it is *.pyc.
#   DIR names  (entry must END in "/"): __pycache__ .pytest_cache .mypy_cache .ruff_cache (tool caches),
#               node_modules (npm output), .venv (venv), dist build .next (bundler output), coverage (reports)
#   FILE names (entry must NOT end in "/"): .DS_Store (Finder metadata), .coverage (coverage data), *.pyc
# Typed on purpose: under --ignored=matching a wholly-ignored directory is reported with a trailing "/",
# so a regular FILE named "build"/".venv", or a symlink (no trailing "/"), never passes as a cache dir.
_REBUILDABLE_DIRS=(__pycache__ .pytest_cache .mypy_cache .ruff_cache node_modules coverage dist build .next .venv)
_REBUILDABLE_FILES=(.DS_Store .coverage)

# _is_rebuildable_ignored PATH: 0 iff PATH (as reported by status; a dir ends in /) is rebuildable.
# LAST component only, never ancestors: a wholly-ignored dir is ONE entry ending in "/" (node_modules/,
# pkg/__pycache__/), so its last component IS the cache name. An entry like build/secrets.env is listed
# separately precisely because build/ itself is NOT ignored, so an ancestor named "build" proves nothing
# about the file and must not make it deletable.
# Parameter expansion only (no globbing / read, so odd characters in names are inert).
_is_rebuildable_ignored() {
  local p="$1" last n
  if [[ "$p" == */ ]]; then
    last="${p%/}"
    last="${last##*/}"
    for n in "${_REBUILDABLE_DIRS[@]}"; do
      [[ "$last" == "$n" ]] && return 0
    done
    return 1
  fi
  last="${p##*/}"
  [[ "$last" == *.pyc ]] && return 0
  for n in "${_REBUILDABLE_FILES[@]}"; do
    [[ "$last" == "$n" ]] && return 0
  done
  return 1
}

# Kept agent worktrees (buildup visibility only; nothing here deletes anything).
KEPT_N=0
KEPT_PATHS=()
KEPT_REASONS=()
_record_kept() { # path reason
  KEPT_PATHS[KEPT_N]="$1"
  KEPT_REASONS[KEPT_N]="$2"
  KEPT_N=$((KEPT_N + 1))
}
_keep_wt() { # reason  (uses $wt_path)
  printf '[groomer] Keeping worktree (%s): %s\n' "$1" "$wt_path"
  _record_kept "$wt_path" "$1"
}

# _dir_identity PATH: print "dev:ino" iff PATH is a real directory (lstat; a symlink is NOT one).
# argv only — PATH is never interpolated into the python source. Non-zero + no output on any failure.
_dir_identity() {
  python3 -I "$_GROOM_FS" identity "$1" 2>/dev/null
}

# _rename_path SRC DST: rename(2) ONLY. Never `mv` (it falls back to copy+delete across filesystems).
_rename_path() {
  python3 -I "$_GROOM_FS" rename "$1" "$2" 2>/dev/null
}

# _quarantine_root_ok: create/validate $GROOM_QROOT (mode 700, real directory, never a symlink).
_quarantine_root_ok() {
  [[ -n "${HOME:-}" ]] || return 1
  [[ -L "$GROOM_QROOT" ]] && return 1
  mkdir -p -- "$GROOM_QROOT" 2>/dev/null || return 1
  [[ -L "$GROOM_QROOT" ]] && return 1
  [[ -d "$GROOM_QROOT" ]] || return 1
  chmod 700 "$GROOM_QROOT" 2>/dev/null || return 1
  # After the chmod: must be a real dir, owned by us, with no group/other write bits (lstat).
  python3 -I "$_GROOM_FS" root-ok "$GROOM_QROOT" 2>/dev/null || return 1
  # Resolve once; the pinned-cwd delete compares against this.
  GROOM_QROOT_REAL="$(cd -- "$GROOM_QROOT" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$GROOM_QROOT_REAL" ]] || return 1
  return 0
}

# _quarantine_delete QDIR NAME: delete QDIR/NAME then QDIR, from a PINNED cwd. cd into QDIR, require
# its resolved cwd to be exactly $GROOM_QROOT_REAL/<qdir basename> (a swapped-in symlink resolves
# elsewhere -> refuse), then delete ./name via `rmtree-pinned` (cast_guard.safe_rmtree_pinned walks QDIR
# from "/" with O_NOFOLLOW fds, so even an ancestor swapped for a symlink after the check cannot
# redirect the delete) and remove the emptied QDIR with a plain "./base" rmdir.
_quarantine_delete() {
  local qd="$1" name="$2" base="${1##*/}"
  (
    cd -- "$qd" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$GROOM_QROOT_REAL/$base" ]] || exit 1
    python3 -I "$_GROOM_FS" rmtree-pinned "$GROOM_QROOT_REAL/$base" "$name" "$GROOM_QROOT_REAL" || exit 1
    cd .. 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$GROOM_QROOT_REAL" ]] || exit 1
    rmdir -- "./$base"
  ) 2>/dev/null
}

# _remove_registry_entry WT_PATH: remove ONLY the registry dir (.git/worktrees/<id>) whose gitdir file
# names WT_PATH/.git. Pinned cwd (must resolve to exactly <real top>/.git/worktrees); symlinked entries
# and non-regular gitdir files are skipped; exactly one match is required, else non-zero (caller WARNs).
# The pinned subshell only IDENTIFIES the entry (prints its basename); the delete is `rmtree-pinned`,
# which walks .git/worktrees from "/" with O_NOFOLLOW fds (.git/worktrees is agent-writable, so an
# absolute-path delete could be redirected by a swapped ancestor).
_remove_registry_entry() {
  local want="$1/.git" reg="$GROOM_TOP_REAL/.git/worktrees" name
  name="$(
    exec 2>/dev/null
    cd -- "$reg" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$reg" ]] || exit 1
    hits=0
    id=""
    for e in ./*; do
      [[ -L "$e" ]] && continue
      [[ -d "$e" ]] || continue
      [[ -L "$e/gitdir" ]] && continue
      [[ -f "$e/gitdir" ]] || continue
      content="$(cat -- "$e/gitdir" 2>/dev/null)" || continue
      if [[ "$content" == "$want" ]]; then
        hits=$((hits + 1))
        id="$e"
      fi
    done
    [[ "$hits" -eq 1 && -n "$id" ]] || exit 1
    printf '%s\n' "${id#./}"
  )" || return 1
  [[ -n "$name" ]] || return 1
  python3 -I "$_GROOM_FS" rmtree-pinned "$reg" "$name" "$reg" 2>/dev/null
}
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  GROOM_TOP="$(cast_git_safe "$GROOM_REPO" rev-parse --show-toplevel 2>/dev/null || true)"
  GROOM_TOP_REAL=""
  if [[ -n "$GROOM_TOP" && -d "$GROOM_TOP" ]]; then
    GROOM_TOP_REAL="$(cd "$GROOM_TOP" 2>/dev/null && pwd -P)" || GROOM_TOP_REAL=""
  fi
  GROOM_QROOT="${HOME:-}/.claude/groomer-quarantine"
  while IFS= read -r wt_line; do
    [[ -z "$wt_line" ]] && continue
    # Listing format: "U:<path>" (unlocked) or "L:<path>" (locked).
    wt_state="${wt_line%%:*}"
    wt_path="${wt_line#?:}"
    [[ -z "$wt_path" ]] && continue
    # Skip the main worktree (first entry, no extra path)
    [[ "$wt_path" == "$GROOM_TOP" ]] && continue
    if [[ ! -d "$wt_path" ]]; then continue; fi
    # Locked worktrees are never removed (git's own `worktree remove --force` refused them too).
    if [[ "$wt_state" == "L" ]]; then
      printf '[groomer] Keeping worktree (locked): %s\n' "$wt_path"
      case "${wt_path##*/}" in
        agent-* | worktree-agent-*)
          [[ -n "${GROOM_TOP_REAL:-}" && "${wt_path%/*}" == "$GROOM_TOP_REAL/.claude/worktrees" ]] && _record_kept "$wt_path" "locked"
          ;;
      esac
      continue
    fi
    # Capture the directory's dev:ino BEFORE any gate runs; after the rename we re-verify the moved
    # object is this exact inode. Must be a real directory (lstat: a symlink is refused). Any doubt -> keep.
    if ! wt_id="$(_dir_identity "$wt_path")" || [[ -z "$wt_id" ]]; then
      printf '[groomer] Keeping worktree (not an agent worktree path): %s\n' "$wt_path"
      continue
    fi
    # ── Identity gates (SECURITY; any doubt -> keep). The registry entry
    # (.git/worktrees/<id>/gitdir) and the worktree's own .git file are agent-writable, so a forged
    # entry can aim `worktree remove --force` at ANY directory (or, via a symlink, at a symlink
    # target) while every content check below reads a different repo's clean state. Only a REAL
    # agent worktree is ever removed: directly <repo>/.claude/worktrees/<agent-*|worktree-agent-*>,
    # compared on RESOLVED paths (no symlink anywhere), whose git common dir is THIS repo's .git.
    wt_name="${wt_path##*/}"
    wt_expected="$GROOM_TOP_REAL/.claude/worktrees/$wt_name"
    wt_resolved="$(cd "$wt_path" 2>/dev/null && pwd -P)" || wt_resolved=""
    if [[ -z "$GROOM_TOP_REAL" ]] || [[ -z "$wt_resolved" ]] || [[ -L "$wt_path" ]] ||
      { [[ "$wt_name" != agent-* ]] && [[ "$wt_name" != worktree-agent-* ]]; } ||
      [[ "$wt_resolved" != "$wt_expected" ]]; then
      printf '[groomer] Keeping worktree (not an agent worktree path): %s\n' "$wt_path"
      continue
    fi
    wt_common="$(cast_git_safe "$wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || wt_common=""
    if [[ -z "$wt_common" ]] || [[ ! "$wt_common" -ef "$GROOM_TOP_REAL/.git" ]]; then
      printf '[groomer] Keeping worktree (not this repo'"'"'s worktree — identity mismatch): %s\n' "$wt_path"
      continue
    fi
    # Check: no uncommitted changes
    # FAIL-SAFE submodule guard. The dirty check below uses --ignore-submodules=all (a submodule's
    # own config could define filter drivers we never enumerated), so uncommitted work INSIDE a
    # submodule would be invisible to it and `worktree remove --force` would destroy it. Keep any
    # worktree that has a .gitmodules or a gitlink (mode 160000) in its index. `ls-files -s` reads
    # the index only (no stat compare, no filters). An unreadable index also keeps the worktree.
    if [[ -e "$wt_path/.gitmodules" ]]; then
      _keep_wt 'has submodules — check manually'
      continue
    fi
    if ! _wt_index="$(cast_git_safe "$wt_path" ls-files -s 2>/dev/null)"; then
      _keep_wt 'index unreadable — check manually'
      continue
    fi
    if printf '%s\n' "$_wt_index" | grep -q '^160000 '; then
      _keep_wt 'has submodules — check manually'
      continue
    fi
    # cast_git_safe injects --ignore-submodules=all for diff (safe: submodule worktrees were kept
    # above). Any error (incl. helper rc 2/3/126) falls into the "dirty" keep branch.
    if ! cast_git_safe "$wt_path" diff --quiet --no-ext-diff --no-textconv 2>/dev/null; then
      _keep_wt 'dirty'
      continue
    fi
    # `diff --quiet` ignores UNTRACKED files, and the removal would destroy them: require that
    # `status` shows nothing but IGNORED entries. NUL-delimited (-z) so paths with spaces/newlines
    # parse safely; --ignored=matching reports a wholly-ignored dir (node_modules/) as ONE entry.
    # Ignored entries are tolerated only if REBUILDABLE (see _REBUILDABLE_DIRS/_REBUILDABLE_FILES); anything else
    # (.env, secrets.json ...) keeps the worktree. A git error also keeps the worktree.
    _st_rc=1
    _st_dirty=0
    _st_bad_n=0
    _st_bad=""
    while IFS= read -r -d '' _ent; do
      if [[ "$_ent" == RC=* ]]; then
        _st_rc="${_ent#RC=}"
      elif [[ "$_ent" == '!! '* ]]; then
        if ! _is_rebuildable_ignored "${_ent:3}"; then
          _st_bad_n=$((_st_bad_n + 1))
          if [[ "$_st_bad_n" -le 3 ]]; then
            _ent_disp="${_ent:3}"
            _st_bad="${_st_bad:+$_st_bad, }${_ent_disp//$'\n'/?}"
          fi
        fi
      else
        _st_dirty=1
      fi
    done < <(
      cast_git_safe "$wt_path" status --porcelain=v1 -z --untracked-files=all --ignored=matching 2>/dev/null
      printf 'RC=%s\0' "$?"
    )
    if [[ "$_st_rc" != 0 ]] || [[ "$_st_dirty" -eq 1 ]]; then
      _keep_wt 'uncommitted or untracked files'
      continue
    fi
    if [[ "$_st_bad_n" -gt 0 ]]; then
      printf '[groomer] Keeping worktree (ignored files not in the rebuildable list): %s — %s\n' "$wt_path" "$_st_bad"
      _record_kept "$wt_path" "ignored files not in the rebuildable list"
      continue
    fi
    # Check: no commits ahead of main
    ahead=$(cast_git_safe "$wt_path" rev-list --count "main..HEAD" 2>/dev/null || echo 1)
    if [[ "$ahead" -gt 0 ]]; then
      _keep_wt 'ahead of main'
      continue
    fi
    # Check: directory mtime older than 7 days. Housekeeping only, NOT a security control (mtime is
    # agent-forgeable; the identity gates above are what protect). A find error -> empty -> keep.
    if [[ -z "$(find "$wt_path" -maxdepth 0 -mtime +7 2>/dev/null)" ]]; then
      _keep_wt 'recently touched'
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[dry-run] Would remove worktree: %s\n' "$wt_path"
    else
      # ── Quarantine-by-rename (TOCTOU defence). Every gate above ran on a PATH an agent can keep
      # swapping (leaf -> symlink, or the parent .claude/worktrees -> symlink to e.g. ~/.claude), so
      # deleting by that path could hit a victim. Instead: rename(2) the directory into a root the
      # sandbox cannot write, re-verify the MOVED object is the same dev:ino we captured before the
      # gates, and only then delete it there (rm never follows symlinks inside a tree). rename(2)
      # never copies, so a cross-filesystem move fails closed (EXDEV -> keep).
      if ! _quarantine_root_ok; then
        printf '[groomer] WARN: quarantine root unusable (%s) — keeping worktree: %s\n' "$GROOM_QROOT" "$wt_path" >&2
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi
      if ! qdir="$(mktemp -d "$GROOM_QROOT/wt.XXXXXX" 2>/dev/null)" || [[ -z "$qdir" ]]; then
        printf '[groomer] WARN: could not create quarantine dir — keeping worktree: %s\n' "$wt_path" >&2
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi
      if ! _rename_path "$wt_path" "$qdir/$wt_name"; then
        printf '[groomer] WARN: could not quarantine worktree (rename failed) — kept: %s\n' "$wt_path" >&2
        rmdir "$qdir" 2>/dev/null || true
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi
      wt_moved_id="$(_dir_identity "$qdir/$wt_name")" || wt_moved_id=""
      if [[ -z "$wt_moved_id" ]] || [[ "$wt_moved_id" != "$wt_id" ]]; then
        if _rename_path "$qdir/$wt_name" "$wt_path"; then
          printf '[groomer] WARN: worktree identity changed during removal (swap detected) — restored, NOT deleted: %s\n' "$wt_path" >&2
          rmdir "$qdir" 2>/dev/null || true
        else
          printf '[groomer] WARN: worktree identity changed during removal (swap detected) — left in quarantine, NOT deleted: %s\n' "$qdir/$wt_name" >&2
        fi
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi
      if _quarantine_delete "$qdir" "$wt_name"; then
        printf '[groomer] Removed worktree: %s\n' "$wt_path"
        DELETED_WORKTREES=$((DELETED_WORKTREES + 1))
        # Drop ONLY this worktree's own registry entry. NEVER `git worktree prune`: prune follows an
        # agent-planted symlinked .git/worktrees/<id> and deletes its target.
        if ! _remove_registry_entry "$wt_path"; then
          printf '[groomer] WARN: registry entry not removed — remove it by hand after checking it is not a symlink (never run git worktree prune: it follows symlinked entries): %s\n' "$wt_path" >&2
          WARN_COUNT=$((WARN_COUNT + 1))
        fi
      else
        printf '[groomer] WARN: could not fully delete quarantined worktree: %s\n' "$qdir" >&2
        WARN_COUNT=$((WARN_COUNT + 1))
      fi
    fi
  done < <(cast_git_safe "$GROOM_REPO" worktree list --porcelain 2>/dev/null | awk '
    function flush() { if (p != "") print (l ? "L:" : "U:") p }
    /^worktree / { flush(); p = substr($0, 10); l = 0; next }
    /^locked/ { l = 1 }
    END { flush() }
  ' || true)
fi

# ── Summary ───────────────────────────────────────────────────────────────
DRY_LABEL=""
[[ "$DRY_RUN" -eq 1 ]] && DRY_LABEL=" (dry-run)"
printf '\nGroomed%s: %d worktree-agent + %d merged feature/fix branches' \
  "$DRY_LABEL" "$DELETED_WORKTREE_AGENT" "$DELETED_MERGED"
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  printf ', %d worktrees, %d agent worktrees kept' "$DELETED_WORKTREES" "$KEPT_N"
fi
printf '.\n'

# Buildup visibility (never deletes): old kept agent worktrees, and leftover quarantine dirs.
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  _stale_shown=0
  _stale_total=0
  _i=0
  while [[ "$_i" -lt "$KEPT_N" ]]; do
    if [[ -n "$(find "${KEPT_PATHS[_i]}" -maxdepth 0 -mtime +30 2>/dev/null)" ]]; then
      _stale_total=$((_stale_total + 1))
      if [[ "$_stale_shown" -lt 20 ]]; then
        printf '[groomer] STALE (kept >30d, review manually): %s — %s\n' "${KEPT_PATHS[_i]}" "${KEPT_REASONS[_i]}"
        _stale_shown=$((_stale_shown + 1))
      fi
    fi
    _i=$((_i + 1))
  done
  [[ "$_stale_total" -gt "$_stale_shown" ]] && printf '[groomer] ... and %d more stale kept worktrees\n' "$((_stale_total - _stale_shown))"
  if [[ -d "${GROOM_QROOT:-}" && ! -L "${GROOM_QROOT:-}" ]]; then
    _q_left="$(find "$GROOM_QROOT" -mindepth 1 -maxdepth 1 -type d -name 'wt.*' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${_q_left:-0}" -gt 0 ]]; then
      printf '[groomer] WARN: %s leftover quarantine dir(s) in %s — inspect and remove manually\n' "$_q_left" "$GROOM_QROOT" >&2
    fi
  fi
fi

# Exit 0 always — groomer is advisory
exit 0
