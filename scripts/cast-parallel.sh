#!/usr/bin/env bash
# cast-parallel.sh — CAST Parallel Plan Executor
#
# Purpose:
#   Splits an Agent Dispatch Manifest plan into two batch streams and runs
#   each in a separate git worktree via `claude --headless`. Merges results
#   back to the current branch when both sessions complete.
#
# Usage:
#   cast-parallel.sh [--dry-run] [--split N] <plan-file>
#
# Flags:
#   --dry-run       Show batch split without executing
#   --split N       Split after batch N (default: auto-midpoint)
#   --help, -h      Show this help
#
# Exit codes:
#   0 — both sessions completed and merged
#   1 — runtime/merge error
#   2 — usage / argument error

# ── Subprocess guard: do not run recursively inside CAST subagent chains ──────
if [ "${CAST_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Colors (only when attached to a tty) ─────────────────────────────────────
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  C_BOLD='\033[1m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_RED='\033[0;31m'
  C_CYAN='\033[0;36m'
  C_DIM='\033[2m'
  C_RESET='\033[0m'
else
  C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_DIM='' C_RESET=''
fi

# ── Logging helpers ───────────────────────────────────────────────────────────
_info()    { printf "${C_CYAN}[cast-parallel]${C_RESET} %s\n" "$*"; }
_success() { printf "${C_GREEN}[cast-parallel]${C_RESET} %s\n" "$*"; }
_warn()    { printf "${C_YELLOW}[cast-parallel] WARN:${C_RESET} %s\n" "$*" >&2; }
_error()   { printf "${C_RED}[cast-parallel] ERROR:${C_RESET} %s\n" "$*" >&2; }
_header()  { printf "\n${C_BOLD}%s${C_RESET}\n" "$*"; }
_dim()     { printf "${C_DIM}%s${C_RESET}\n" "$*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=0
SPLIT_POINT=""
PLAN_FILE=""

_usage() {
  cat <<USAGE
Usage: cast-parallel.sh [--dry-run] [--split N] <plan-file>

  <plan-file>         Plan file containing a \`json dispatch\` block
  --dry-run           Show batch split without executing
  --split N           Split after batch N (default: auto-midpoint)
  --help, -h          Show this help

Examples:
  cast-parallel.sh --dry-run ~/.claude/plans/my-plan.md
  cast-parallel.sh --split 2 ~/.claude/plans/my-plan.md
  cast-parallel.sh --split 3 --dry-run ~/.claude/plans/my-plan.md
USAGE
}

while [ "${#}" -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --split)
      if [ -z "${2:-}" ]; then
        _error "--split requires a number"
        exit 2
      fi
      SPLIT_POINT="$2"
      shift 2
      ;;
    --help|-h) _usage; exit 0 ;;
    -*)
      _error "Unknown flag: $1"
      _usage >&2
      exit 2
      ;;
    *)
      if [ -z "$PLAN_FILE" ]; then
        PLAN_FILE="$1"
      else
        _error "Unexpected argument: $1"
        _usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$PLAN_FILE" ]; then
  _error "Plan file is required."
  _usage >&2
  exit 2
fi

# Expand ~ in path
PLAN_FILE="${PLAN_FILE/#\~/$HOME}"

if [ ! -f "$PLAN_FILE" ]; then
  _error "Plan file not found: $PLAN_FILE"
  exit 2
fi

# ── JSON extraction: parse the `json dispatch` fenced block ──────────────────
_extract_dispatch_json() {
  local plan_file="$1"
  awk '
    /^```json dispatch$/ { capture=1; next }
    /^```$/ && capture   { capture=0; next }
    capture              { print }
  ' "$plan_file"
}

DISPATCH_JSON="$(_extract_dispatch_json "$PLAN_FILE")"

if [ -z "$DISPATCH_JSON" ]; then
  _error "No \`json dispatch\` fenced block found in: $PLAN_FILE"
  exit 1
fi

# ── Parse plan metadata ──────────────────────────────────────────────────────
PLAN_ID=$(printf '%s' "$DISPATCH_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('plan_id', ''))
except Exception:
    print('')
    sys.exit(1)
" 2>/dev/null) || {
  _error "Failed to parse dispatch JSON."
  exit 1
}

BATCH_COUNT=$(printf '%s' "$DISPATCH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('batches', [])))
" 2>/dev/null || echo "0")

if [ "$BATCH_COUNT" -eq 0 ]; then
  _error "No batches found in dispatch manifest."
  exit 1
fi

# ── Compute split point ──────────────────────────────────────────────────────
_compute_split() {
  if [ -n "$SPLIT_POINT" ]; then
    # Validate user-provided split point
    if ! [[ "$SPLIT_POINT" =~ ^[0-9]+$ ]]; then
      _error "--split must be a positive integer"
      exit 2
    fi
    if [ "$SPLIT_POINT" -lt 1 ] || [ "$SPLIT_POINT" -ge "$BATCH_COUNT" ]; then
      _error "--split N must be between 1 and $((BATCH_COUNT - 1)) (got $SPLIT_POINT, batch count is $BATCH_COUNT)"
      exit 1
    fi
  else
    # Auto midpoint
    SPLIT_POINT=$(( BATCH_COUNT / 2 ))
    if [ "$SPLIT_POINT" -lt 1 ]; then
      SPLIT_POINT=1
    fi
  fi
}

_compute_split

# ── Build batch ID lists for each stream ──────────────────────────────────────
STREAM_A_IDS=$(printf '%s' "$DISPATCH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
split = int(sys.argv[1])
batches = d.get('batches', [])
ids = [str(b['id']) for b in batches[:split]]
print(','.join(ids))
" "$SPLIT_POINT" 2>/dev/null || echo "")

STREAM_B_IDS=$(printf '%s' "$DISPATCH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
split = int(sys.argv[1])
batches = d.get('batches', [])
ids = [str(b['id']) for b in batches[split:]]
print(','.join(ids))
" "$SPLIT_POINT" 2>/dev/null || echo "")

# ── Dry-run output ────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  _header "cast parallel — dry run"
  _dim "  Plan: $PLAN_FILE"
  _dim "  Plan ID: $PLAN_ID"
  _dim "  Total batches: $BATCH_COUNT"
  _dim "  Split after batch: $SPLIT_POINT"
  echo ""
  printf "  Stream A (worktree-a): batches %s\n" "$STREAM_A_IDS"
  printf "  Stream B (worktree-b): batches %s\n" "$STREAM_B_IDS"
  exit 0
fi

# ── Worktree setup ────────────────────────────────────────────────────────────
WORKTREE_BASE="${HOME}/.claude/worktrees"
WORKTREE_A="${WORKTREE_BASE}/parallel-a"
WORKTREE_B="${WORKTREE_BASE}/parallel-b"
BRANCH_A="cast-parallel-a-$$"
BRANCH_B="cast-parallel-b-$$"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

_setup_worktrees() {
  _info "Setting up worktrees..."
  mkdir -p "$WORKTREE_BASE"

  # Remove existing worktrees if present (idempotent)
  if [ -d "$WORKTREE_A" ]; then
    git worktree remove --force "$WORKTREE_A" 2>/dev/null || true
  fi
  if [ -d "$WORKTREE_B" ]; then
    git worktree remove --force "$WORKTREE_B" 2>/dev/null || true
  fi

  # Clean up stale branch refs
  git branch -D "$BRANCH_A" 2>/dev/null || true
  git branch -D "$BRANCH_B" 2>/dev/null || true

  git worktree add "$WORKTREE_A" -b "$BRANCH_A" HEAD
  git worktree add "$WORKTREE_B" -b "$BRANCH_B" HEAD

  _success "Worktrees created:"
  _dim "  A: $WORKTREE_A ($BRANCH_A)"
  _dim "  B: $WORKTREE_B ($BRANCH_B)"
}

# ── Launch headless sessions ──────────────────────────────────────────────────
LOG_A="${TMPDIR:-/tmp}/cast-parallel-${PLAN_ID}-stream-a.log"
LOG_B="${TMPDIR:-/tmp}/cast-parallel-${PLAN_ID}-stream-b.log"
PID_A=""
PID_B=""

_launch_sessions() {
  _info "Launching parallel sessions..."

  local prompt_a="Execute batches ${STREAM_A_IDS} from the plan at ${PLAN_FILE}. You are Stream A in a parallel execution. Work only on the batches assigned to you. Follow the agent dispatch manifest exactly."
  local prompt_b="Execute batches ${STREAM_B_IDS} from the plan at ${PLAN_FILE}. You are Stream B in a parallel execution. Work only on the batches assigned to you. Follow the agent dispatch manifest exactly."

  (cd "$WORKTREE_A" && claude --headless --dangerously-skip-permissions -p "$prompt_a" > "$LOG_A" 2>&1) &
  PID_A=$!

  (cd "$WORKTREE_B" && claude --headless --dangerously-skip-permissions -p "$prompt_b" > "$LOG_B" 2>&1) &
  PID_B=$!

  _info "Stream A PID: $PID_A (log: $LOG_A)"
  _info "Stream B PID: $PID_B (log: $LOG_B)"
}

# ── Wait for sessions ─────────────────────────────────────────────────────────
_wait_sessions() {
  _info "Waiting for parallel sessions to complete..."

  local exit_a=0 exit_b=0

  wait "$PID_A" || exit_a=$?
  wait "$PID_B" || exit_b=$?

  if [ "$exit_a" -ne 0 ]; then
    _error "Stream A exited with code $exit_a"
    _error "Last 20 lines of Stream A log:"
    tail -20 "$LOG_A" >&2 || true
  else
    _success "Stream A completed."
  fi

  if [ "$exit_b" -ne 0 ]; then
    _error "Stream B exited with code $exit_b"
    _error "Last 20 lines of Stream B log:"
    tail -20 "$LOG_B" >&2 || true
  else
    _success "Stream B completed."
  fi

  if [ "$exit_a" -ne 0 ] || [ "$exit_b" -ne 0 ]; then
    _error "One or both sessions failed. Logs preserved at:"
    _error "  A: $LOG_A"
    _error "  B: $LOG_B"
    return 1
  fi
}

# ── Merge results ─────────────────────────────────────────────────────────────
_merge_results() {
  _info "Merging results..."

  # First merge B into A
  if ! (cd "$WORKTREE_A" && git merge "$BRANCH_B" --no-edit 2>&1); then
    _error "Merge conflict: $BRANCH_B into $BRANCH_A"
    _error "Conflicting files:"
    (cd "$WORKTREE_A" && git diff --name-only --diff-filter=U) >&2 || true
    return 1
  fi
  _success "Merged Stream B into Stream A."

  # Now merge A (which has both) back into original branch
  if ! git merge "$BRANCH_A" --no-edit 2>&1; then
    _error "Merge conflict: $BRANCH_A into $CURRENT_BRANCH"
    _error "Conflicting files:"
    git diff --name-only --diff-filter=U >&2 || true
    return 1
  fi
  _success "Merged combined result into $CURRENT_BRANCH."
}

# ── Cleanup worktrees ────────────────────────────────────────────────────────
_cleanup_worktrees() {
  _info "Cleaning up worktrees..."
  git worktree remove --force "$WORKTREE_A" 2>/dev/null || true
  git worktree remove --force "$WORKTREE_B" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
  git branch -D "$BRANCH_A" 2>/dev/null || true
  git branch -D "$BRANCH_B" 2>/dev/null || true
  _success "Worktrees cleaned up."
}

# ── DB logging helper ─────────────────────────────────────────────────────────
_db_log() {
  local event_type="$1"
  local message="$2"
  local db_log_script
  db_log_script="$(dirname "$0")/cast-db-log.py"
  if [ -f "$db_log_script" ]; then
    python3 "$db_log_script" --event "$event_type" --message "$message" 2>/dev/null || true
  fi
}

# ── Trap for cleanup on interrupt ─────────────────────────────────────────────
_on_exit() {
  if [ -n "$PID_A" ] && kill -0 "$PID_A" 2>/dev/null; then
    kill "$PID_A" 2>/dev/null || true
  fi
  if [ -n "$PID_B" ] && kill -0 "$PID_B" 2>/dev/null; then
    kill "$PID_B" 2>/dev/null || true
  fi
  _cleanup_worktrees 2>/dev/null || true
}
trap _on_exit INT TERM

# ── Main flow ─────────────────────────────────────────────────────────────────
_header "cast parallel — ${PLAN_ID} (${BATCH_COUNT} batches, split at ${SPLIT_POINT})"
_dim "  Plan file: $PLAN_FILE"
_dim "  Stream A: batches $STREAM_A_IDS"
_dim "  Stream B: batches $STREAM_B_IDS"
echo ""

_db_log "parallel_start" "Plan: $PLAN_ID, split at batch $SPLIT_POINT"

_setup_worktrees

_launch_sessions

if ! _wait_sessions; then
  _db_log "parallel_fail" "One or both sessions failed"
  _cleanup_worktrees
  exit 1
fi

_db_log "parallel_streams_done" "Both streams complete"

if ! _merge_results; then
  _db_log "parallel_merge_conflict" "Merge conflict during result merge"
  _error "Merge failed. Worktrees preserved for manual resolution:"
  _error "  A: $WORKTREE_A"
  _error "  B: $WORKTREE_B"
  exit 1
fi

_db_log "parallel_complete" "Plan $PLAN_ID parallel execution complete"

_cleanup_worktrees

_success ""
_success "Parallel execution complete. All results merged into $CURRENT_BRANCH."
