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
_GROOM_LIB="$(dirname "$0")/cast-hook-lib.sh"
unset -f cast_git_safe 2>/dev/null || true
unset _CAST_HOOK_LIB_LOADED
# shellcheck source=cast-hook-lib.sh
# (-r first: bash 3.2 exits the shell silently on a failed `source` of a missing file.)
if [[ ! -r "$_GROOM_LIB" ]] || ! source "$_GROOM_LIB" 2>/dev/null || ! declare -F cast_git_safe >/dev/null 2>&1; then
  printf '[cast-branch-groomer] ERROR: cannot load cast_git_safe from %s; refusing to run git\n' "$_GROOM_LIB" >&2
  _log_error "cannot load cast_git_safe from $_GROOM_LIB"
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
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  GROOM_TOP="$(cast_git_safe "$GROOM_REPO" rev-parse --show-toplevel 2>/dev/null || true)"
  GROOM_TOP_REAL=""
  if [[ -n "$GROOM_TOP" && -d "$GROOM_TOP" ]]; then
    GROOM_TOP_REAL="$(cd "$GROOM_TOP" 2>/dev/null && pwd -P)" || GROOM_TOP_REAL=""
  fi
  while IFS= read -r wt_path; do
    [[ -z "$wt_path" ]] && continue
    # Skip the main worktree (first entry, no extra path)
    [[ "$wt_path" == "$GROOM_TOP" ]] && continue
    if [[ ! -d "$wt_path" ]]; then continue; fi
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
      printf '[groomer] Keeping worktree (has submodules — check manually): %s\n' "$wt_path"
      continue
    fi
    if ! _wt_index="$(cast_git_safe "$wt_path" ls-files -s 2>/dev/null)"; then
      printf '[groomer] Keeping worktree (index unreadable — check manually): %s\n' "$wt_path"
      continue
    fi
    if printf '%s\n' "$_wt_index" | grep -q '^160000 '; then
      printf '[groomer] Keeping worktree (has submodules — check manually): %s\n' "$wt_path"
      continue
    fi
    # cast_git_safe injects --ignore-submodules=all for diff (safe: submodule worktrees were kept
    # above). Any error (incl. helper rc 2/3/126) falls into the "dirty" keep branch.
    if ! cast_git_safe "$wt_path" diff --quiet --no-ext-diff --no-textconv 2>/dev/null; then
      printf '[groomer] Keeping worktree (dirty): %s\n' "$wt_path"
      continue
    fi
    # `diff --quiet` ignores UNTRACKED files, and `worktree remove --force` would destroy them:
    # require an empty `status` (untracked included). An error also keeps the worktree.
    if ! _wt_status="$(cast_git_safe "$wt_path" status --porcelain --untracked-files=all 2>/dev/null)" ||
      [[ -n "$_wt_status" ]]; then
      printf '[groomer] Keeping worktree (uncommitted or untracked files): %s\n' "$wt_path"
      continue
    fi
    # Check: no commits ahead of main
    ahead=$(cast_git_safe "$wt_path" rev-list --count "main..HEAD" 2>/dev/null || echo 1)
    if [[ "$ahead" -gt 0 ]]; then
      printf '[groomer] Keeping worktree (ahead of main): %s\n' "$wt_path"
      continue
    fi
    # Check: directory mtime older than 7 days. Housekeeping only, NOT a security control (mtime is
    # agent-forgeable; the identity gates above are what protect). A find error -> empty -> keep.
    if [[ -z "$(find "$wt_path" -maxdepth 0 -mtime +7 2>/dev/null)" ]]; then
      printf '[groomer] Keeping worktree (recently touched): %s\n' "$wt_path"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[dry-run] Would remove worktree: %s\n' "$wt_path"
    else
      if cast_git_safe "$GROOM_REPO" worktree remove --force -- "$wt_path" 2>/dev/null; then
        printf '[groomer] Removed worktree: %s\n' "$wt_path"
        DELETED_WORKTREES=$((DELETED_WORKTREES + 1))
      else
        printf '[groomer] WARN: could not remove worktree: %s\n' "$wt_path" >&2
        WARN_COUNT=$((WARN_COUNT + 1))
      fi
    fi
  done < <(cast_git_safe "$GROOM_REPO" worktree list --porcelain 2>/dev/null | grep '^worktree' | awk '{print $2}' || true)
fi

# ── Summary ───────────────────────────────────────────────────────────────
DRY_LABEL=""
[[ "$DRY_RUN" -eq 1 ]] && DRY_LABEL=" (dry-run)"
printf '\nGroomed%s: %d worktree-agent + %d merged feature/fix branches' \
  "$DRY_LABEL" "$DELETED_WORKTREE_AGENT" "$DELETED_MERGED"
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  printf ', %d worktrees' "$DELETED_WORKTREES"
fi
printf '.\n'

# Exit 0 always — groomer is advisory
exit 0
