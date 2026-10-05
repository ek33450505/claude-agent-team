#!/bin/bash
# cast-precompact-guard.sh — PreCompact hook: block AUTO-compaction if any tracked repo is dirty.
# Manual /compact always passes through — only system-triggered compaction is guarded.
# Returns {"decision":"block","reason":"..."} to stdout when dirty repos found.
# Prints nothing (empty stdout) when clean or manual: Claude Code's top-level "decision" field
# accepts only "approve"|"block", so the proceed contract is no stdout + exit 0.
# Exit 0 always.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

# Shared hardened-git primitive (cast_git_safe). If the lib is missing we do NOT fall back to
# bare git: the stub returns 3 (hardening not established), so every repo is treated as
# status-unknown and the dirty check below fails closed. The -r guard matters: on bash 3.2 a
# bare `source <missing-file>` aborts the whole script under set -e (see bash32-source-guard.bats).
_CAST_LIB="$(dirname "$0")/cast-hook-lib.sh"
# shellcheck source=cast-hook-lib.sh
if [[ -r "$_CAST_LIB" ]] && source "$_CAST_LIB"; then
  :
else
  _log_error "cast-hook-lib.sh not loadable beside $0; every repo treated as status-unknown (fail closed)"
  cast_git_safe() { return 3; }
fi

INPUT="$(cat 2>/dev/null || true)"

# Always allow manual /compact — only guard auto-compaction
TRIGGER="$(echo "$INPUT" | python3 -I -c "import sys,json; print(json.loads(sys.stdin.read()).get('trigger','auto'))" 2>/dev/null || echo "auto")"
if [[ "$TRIGGER" == "manual" ]]; then
  CAST_INPUT="$INPUT" python3 "${HOME}/.claude/scripts/cast-precompact-log.py" 2>/dev/null || true
  # proceed: no stdout (top-level "decision" accepts only approve|block)
  exit 0
fi

# Known project roots to check. Add more as needed.
# Reads from cast.db sessions table for recently active project paths (best-effort).
KNOWN_PROJECTS=(
  "${HOME}/Projects/personal/claude-agent-team"
  "${HOME}/Projects/personal/claude-code-dashboard"
  "${HOME}/Projects/personal/cast-dash"
  "${HOME}/Projects/personal/cast-hooks"
)

# Support CAST_EXTRA_PROJECT env var for testability
if [ -n "${CAST_EXTRA_PROJECT:-}" ] && [ -d "$CAST_EXTRA_PROJECT" ]; then
  KNOWN_PROJECTS+=("$CAST_EXTRA_PROJECT")
fi

# Also pull recent project paths from cast.db sessions (last 24h)
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ]; then
  while IFS= read -r proj_path; do
    if [ -n "$proj_path" ] && [ -d "$proj_path" ]; then
      KNOWN_PROJECTS+=("$proj_path")
    fi
  done < <(sqlite3 "$DB_PATH" \
    "SELECT DISTINCT project_root FROM sessions WHERE datetime(started_at) > datetime('now','-1 day') AND project_root IS NOT NULL AND project_root != '' LIMIT 20;" \
    2>/dev/null || true)
fi

DIRTY_REPOS=()
FAILED_REPOS=()

# Hostile-repo hardening. This hook runs OUTSIDE the Bash sandbox over project roots an
# agent can write to, so the dirty check goes through cast_git_safe (cast-hook-lib.sh), which
# neutralises repo-local config exec paths (fsmonitor, filter drivers, hooks incl. config hooks,
# lazy fetch) and ignores submodules. It returns 3 when hardening could not be established
# (git NOT run) and git's own exit code otherwise: ANY non-zero rc BLOCKS (FAILED_REPOS), with a
# reason distinct from "dirty" -- committing cannot fix a repo whose status cannot be read.
for proj in "${KNOWN_PROJECTS[@]}"; do
  # Defensive: reject paths starting with '-' so git -C can't reinterpret as an option
  case "$proj" in -*) continue ;; esac
  [ -d "$proj/.git" ] || continue
  # rc captured without `|| true` masking: a failed status must not read as a clean repo.
  _git_rc=0
  STATUS="$(cast_git_safe "$proj" status --porcelain 2>/dev/null)" || _git_rc=$?
  if [ "$_git_rc" -ne 0 ]; then
    # Fail closed: status unknown => block, with a reason that names the repo.
    _log_error "git status failed in $proj (rc=$_git_rc); blocking (status unknown)"
    FAILED_REPOS+=("$proj (rc=${_git_rc})")
  elif [ -n "$STATUS" ]; then
    DIRTY_REPOS+=("$proj")
  fi
done

# Deduplicate (guard empty-array expansion for bash 3.2 compatibility on macOS;
# use while-read to avoid unquoted-$() word-splitting on paths with spaces)
if [ ${#DIRTY_REPOS[@]} -gt 0 ]; then
  DEDUP=()
  while IFS= read -r _line; do
    DEDUP+=("$_line")
  done < <(printf '%s\n' "${DIRTY_REPOS[@]}" | sort -u)
  DIRTY_REPOS=("${DEDUP[@]}")
fi
if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
  DEDUP=()
  while IFS= read -r _line; do
    DEDUP+=("$_line")
  done < <(printf '%s\n' "${FAILED_REPOS[@]}" | sort -u)
  FAILED_REPOS=("${DEDUP[@]}")
fi

if [ ${#DIRTY_REPOS[@]} -eq 0 ] && [ ${#FAILED_REPOS[@]} -eq 0 ]; then
  # Log observability event (carry forward from cast-pre-compact-hook.sh behavior)
  CAST_INPUT="$INPUT" python3 "${HOME}/.claude/scripts/cast-precompact-log.py" 2>/dev/null || true
  exit 0
fi

# Build the reason JSON safely using python3 to avoid shell quoting issues.
# Pass the repo lists via env vars so the heredoc can use 'PYEOF' (no shell expansion).
# Empty arrays are never expanded (bash 3.2 + set -u). Dirty repos get the "commit" guidance;
# repos whose status could not be read get a separate sentence (commit cannot fix those).
LIST=""
if [ ${#DIRTY_REPOS[@]} -gt 0 ]; then
  LIST="$(printf '%s, ' "${DIRTY_REPOS[@]}" | sed 's/, $//')"
fi
FAILED_LIST=""
if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
  FAILED_LIST="$(printf '%s, ' "${FAILED_REPOS[@]}" | sed 's/, $//')"
fi
FALLBACK_REASON="Uncommitted changes detected"
if [ ${#DIRTY_REPOS[@]} -eq 0 ]; then
  FALLBACK_REASON="Could not read git status for a tracked repo (operator fix needed; committing will not help)"
fi
CAST_DIRTY_LIST="$LIST" CAST_FAILED_LIST="$FAILED_LIST" python3 -I - <<'PYEOF' 2>/dev/null || printf '{"decision":"block","reason":"%s"}\n' "$FALLBACK_REASON"
import json, os
dirty_list = os.environ.get('CAST_DIRTY_LIST', '')
failed_list = os.environ.get('CAST_FAILED_LIST', '')
parts = []
if dirty_list:
    parts.append(f"Uncommitted changes in: {dirty_list}. Commit before compacting (use commit agent).")
if failed_list:
    parts.append(f"Could not read git status for: {failed_list} - this needs an operator fix (check the repo's .git/config); committing will not help. Manual /compact still works.")
print(json.dumps({"decision": "block", "reason": " ".join(parts)}))
PYEOF

# Log observability event
CAST_INPUT="$INPUT" python3 "${HOME}/.claude/scripts/cast-precompact-log.py" 2>/dev/null || true

exit 0
