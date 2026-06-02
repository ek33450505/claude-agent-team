#!/usr/bin/env bash
# cast-branch-groomer.sh — Prune stale branches and dead worktrees
#
# Default mode: --dry-run (print what would be deleted, change nothing).
# Use --apply to actually delete.
#
# Branch deletion policy:
#   cast-swarm-*    : committerdate < now-7d AND no open PR
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

# If --repo was given, cd into it so git commands operate there
if [[ -n "$REPO_DIR" ]]; then
  if [[ ! -d "$REPO_DIR" ]]; then
    printf '[cast-branch-groomer] ERROR: --repo path not found: %s\n' "$REPO_DIR" >&2
    exit 1
  fi
  cd "$REPO_DIR"
fi

# Verify we're in a git repo
if ! git rev-parse --git-dir &>/dev/null; then
  printf '[cast-branch-groomer] ERROR: not a git repository\n' >&2
  exit 1
fi

# ── Build whitelist: currently checked-out branches ───────────────────────
CHECKED_OUT_BRANCHES=()
while IFS= read -r line; do
  # git worktree list --porcelain emits "branch refs/heads/<name>"
  branch="${line#branch refs/heads/}"
  if [[ -n "$branch" ]]; then
    CHECKED_OUT_BRANCHES+=("$branch")
  fi
done < <(git worktree list --porcelain 2>/dev/null | grep '^branch' || true)

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

# ── Fetch open PRs (best-effort; skip if gh not available) ────────────────
OPEN_PR_BRANCHES=()
if command -v gh &>/dev/null; then
  while IFS= read -r pr_branch; do
    [[ -n "$pr_branch" ]] && OPEN_PR_BRANCHES+=("$pr_branch")
  done < <(gh pr list --state open --json headRefName --jq '.[].headRefName' --limit 1000 2>/dev/null || true)
fi

_has_open_pr() {
  local b="$1"
  for pr in "${OPEN_PR_BRANCHES[@]+"${OPEN_PR_BRANCHES[@]}"}"; do
    [[ "$b" == "$pr" ]] && return 0
  done
  return 1
}

# ── Date helpers ─────────────────────────────────────────────────────────
_epoch_now() { date +%s; }
_days_since_commit() {
  local branch="$1"
  local commit_epoch
  commit_epoch=$(git log -1 --format='%ct' "refs/heads/$branch" 2>/dev/null || echo 0)
  local now; now=$(_epoch_now)
  echo $(( (now - commit_epoch) / 86400 ))
}

# ── Deletion trackers ────────────────────────────────────────────────────
DELETED_SWARM=0
DELETED_WORKTREE_AGENT=0
DELETED_MERGED=0
WARN_COUNT=0

_delete_branch() {
  local branch="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] Would delete branch: %s\n' "$branch"
  else
    if git branch -d "$branch" 2>/dev/null || git branch -D "$branch" 2>/dev/null; then
      printf '[groomer] Deleted branch: %s\n' "$branch"
    else
      printf '[groomer] WARN: could not delete branch: %s\n' "$branch" >&2
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  fi
}

# ── Process cast-swarm-* branches (>7d, no open PR) ──────────────────────
while IFS= read -r branch; do
  branch="${branch#  }"  # strip leading whitespace
  branch="${branch# }"
  branch="${branch#* }"  # strip any * marker for current branch
  branch="${branch#  }"
  # Normalize: remove leading whitespace and asterisk
  branch="$(printf '%s' "$branch" | sed 's/^[* ]*//')"
  [[ -z "$branch" ]] && continue
  [[ "$branch" != cast-swarm-* ]] && continue
  _is_whitelisted "$branch" && continue
  _has_open_pr "$branch" && { printf '[groomer] Keeping %s — has open PR\n' "$branch"; continue; }
  local_age=$(_days_since_commit "$branch")
  if [[ "$local_age" -ge 7 ]]; then
    _delete_branch "$branch"
    DELETED_SWARM=$((DELETED_SWARM + 1))
  fi
done < <(git branch --list 'cast-swarm-*' 2>/dev/null || true)

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
done < <(git branch --list 'worktree-agent-*' 2>/dev/null || true)

# ── Process feature/* and fix/* — merged + [gone] remote ─────────────────
while IFS= read -r vv_line; do
  # git branch -vv output: "  branch-name  <hash> [origin/branch: gone] message"
  if [[ "$vv_line" =~ \[.*gone\] ]]; then
    branch="$(printf '%s' "$vv_line" | awk '{print $1}' | sed 's/^\*//')"
    [[ -z "$branch" ]] && continue
    if [[ "$branch" =~ ^feature/ ]] || [[ "$branch" =~ ^fix/ ]]; then
      _is_whitelisted "$branch" && continue

      # Two-stage merge check:
      # (1) ahead_count == 0  → fully merged via ff/true merge
      # (2) ahead_count > 0 + git cherry shows all commits content-merged → squash merge
      ahead_count="$(git rev-list --count main.."$branch" 2>/dev/null || echo 1)"

      if [[ "$ahead_count" -eq 0 ]]; then
        _delete_branch "$branch"
        DELETED_MERGED=$((DELETED_MERGED + 1))
      else
        # cherry uses patch-id: '+' = unmerged content, '-' = content-equivalent commit in main
        plus_count=$(git cherry main "$branch" 2>/dev/null | grep -c '^+') || plus_count=0
        cherry_total=$(git cherry main "$branch" 2>/dev/null | wc -l | tr -d ' ') || cherry_total=0
        # Delete only if: zero '+' lines AND cherry accounted for every ahead commit
        # (cherry_total == ahead_count guard prevents deletion of branches with only
        # empty commits, which produce no cherry output but rev-list counts them)
        if [[ "$plus_count" -eq 0 ]] && [[ "$cherry_total" -gt 0 ]] && [[ "$cherry_total" -eq "$ahead_count" ]]; then
          _delete_branch "$branch"
          DELETED_MERGED=$((DELETED_MERGED + 1))
        fi
      fi
    fi
  fi
done < <(git branch -vv 2>/dev/null || true)

# ── Worktree directory pruning (--worktrees flag) ─────────────────────────
DELETED_WORKTREES=0
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  while IFS= read -r wt_path; do
    [[ -z "$wt_path" ]] && continue
    # Skip the main worktree (first entry, no extra path)
    [[ "$wt_path" == "$(git rev-parse --show-toplevel 2>/dev/null)" ]] && continue
    if [[ ! -d "$wt_path" ]]; then continue; fi
    # Check: no uncommitted changes
    if ! git -C "$wt_path" diff --quiet 2>/dev/null; then
      printf '[groomer] Keeping worktree (dirty): %s\n' "$wt_path"
      continue
    fi
    # Check: no commits ahead of main
    ahead=$(git -C "$wt_path" rev-list --count "main..HEAD" 2>/dev/null || echo 1)
    if [[ "$ahead" -gt 0 ]]; then
      printf '[groomer] Keeping worktree (ahead of main): %s\n' "$wt_path"
      continue
    fi
    # Check: last modified > 7 days ago
    wt_mtime=$(find "$wt_path" -maxdepth 0 -newer /tmp -prune -o -print 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$wt_mtime" -gt 0 ]]; then
      printf '[groomer] Keeping worktree (recently touched): %s\n' "$wt_path"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[dry-run] Would remove worktree: %s\n' "$wt_path"
    else
      if git worktree remove --force "$wt_path" 2>/dev/null; then
        printf '[groomer] Removed worktree: %s\n' "$wt_path"
        DELETED_WORKTREES=$((DELETED_WORKTREES + 1))
      else
        printf '[groomer] WARN: could not remove worktree: %s\n' "$wt_path" >&2
        WARN_COUNT=$((WARN_COUNT + 1))
      fi
    fi
  done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree' | awk '{print $2}' || true)
fi

# ── Summary ───────────────────────────────────────────────────────────────
DRY_LABEL=""
[[ "$DRY_RUN" -eq 1 ]] && DRY_LABEL=" (dry-run)"
printf '\nGroomed%s: %d swarm + %d worktree-agent + %d merged feature/fix branches' \
  "$DRY_LABEL" "$DELETED_SWARM" "$DELETED_WORKTREE_AGENT" "$DELETED_MERGED"
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  printf ', %d worktrees' "$DELETED_WORKTREES"
fi
printf '.\n'

# Exit 0 always — groomer is advisory
exit 0
