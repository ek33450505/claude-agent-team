#!/bin/bash
# cast-precompact-guard.sh — PreCompact hook: block AUTO-compaction if any tracked repo is dirty.
# Manual /compact always passes through — only system-triggered compaction is guarded.
# Returns {"decision":"block","reason":"..."} to stdout when dirty repos found.
# Returns {"decision":"allow"} when clean.
# Exit 0 always.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

INPUT="$(cat 2>/dev/null || true)"

# Always allow manual /compact — only guard auto-compaction
TRIGGER="$(echo "$INPUT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('trigger','auto'))" 2>/dev/null || echo "auto")"
if [[ "$TRIGGER" == "manual" ]]; then
  CAST_INPUT="$INPUT" python3 "${HOME}/.claude/scripts/cast-precompact-log.py" 2>/dev/null || true
  printf '{"decision":"allow"}\n'
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

# Hostile-repo hardening. This hook runs OUTSIDE the Bash sandbox over project roots an
# agent can write to, so repo-local config an agent plants must not be able to execute
# code during the dirty check: core.fsmonitor (a program run by `git status`) and
# filter.<drv>.clean/process (run when status re-hashes a stat-dirty tracked file).
# fsmonitor is forced off by -c; filter drivers are enumerated from config (a read —
# nothing is executed) and each one's exec knobs are blanked. Bash 3.2-safe (no declare -A).
# Inherited GIT_CONFIG_PARAMETERS/GLOBAL/SYSTEM are unset (env -u): GIT_CONFIG_PARAMETERS would
# override the env-indexed keys; the fixed keys are ALSO passed as -c (belt and braces).
# Submodules are ignored (--ignore-submodules=all): their OWN config could define filter drivers
# we never enumerated. Dirty-submodule detection is intentionally lost.
SAFE_GIT_ENV=()
# _safe_git_args <repo-dir> — populate SAFE_GIT_ENV (env assignments for `env ... git`). All
# hardening config goes through GIT_CONFIG_COUNT/KEY_i/VALUE_i, NOT `-c k=v`: a filter driver
# name containing '=' would be mis-split by -c parsing and escape the blanking. The count is
# set explicitly with keys from index 0, so an inherited GIT_CONFIG_COUNT cannot add entries.
_safe_git_args() {
  local _key _drv _n=0 _k
  SAFE_GIT_ENV=()
  _sg_add() { SAFE_GIT_ENV+=("GIT_CONFIG_KEY_${_n}=$1" "GIT_CONFIG_VALUE_${_n}=$2"); _n=$((_n + 1)); }
  _sg_add core.fsmonitor false
  _sg_add core.untrackedCache false
  _sg_add core.hooksPath /dev/null
  _sg_add log.showSignature false
  while IFS= read -r -d '' _key; do
    _drv="${_key#filter.}"
    [[ "$_drv" == *.* ]] || continue
    _drv="${_drv%.*}"
    for _k in clean smudge process; do _sg_add "filter.${_drv}.${_k}" ""; done
    _sg_add "filter.${_drv}.required" false
  done < <(git -C "$1" config -z --name-only --get-regexp '^filter\.' 2>/dev/null || true)
  SAFE_GIT_ENV+=("GIT_CONFIG_COUNT=${_n}")
}

for proj in "${KNOWN_PROJECTS[@]}"; do
  # Defensive: reject paths starting with '-' so git -C can't reinterpret as an option
  case "$proj" in -*) continue ;; esac
  [ -d "$proj/.git" ] || continue
  _safe_git_args "$proj"
  STATUS="$(GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM "${SAFE_GIT_ENV[@]}" git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false -c core.untrackedCache=false --no-replace-objects --no-optional-locks -C "$proj" status --porcelain --ignore-submodules=all 2>/dev/null || true)"
  if [ -n "$STATUS" ]; then
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

if [ ${#DIRTY_REPOS[@]} -eq 0 ]; then
  # Log observability event (carry forward from cast-pre-compact-hook.sh behavior)
  CAST_INPUT="$INPUT" python3 "${HOME}/.claude/scripts/cast-precompact-log.py" 2>/dev/null || true
  printf '{"decision":"allow"}\n'
  exit 0
fi

# Build the reason JSON safely using python3 to avoid shell quoting issues.
# Pass the dirty-repo list via env var so the heredoc can use 'PYEOF' (no shell expansion).
LIST="$(printf '%s, ' "${DIRTY_REPOS[@]}" | sed 's/, $//')"
CAST_DIRTY_LIST="$LIST" python3 - <<'PYEOF' 2>/dev/null || printf '{"decision":"block","reason":"Uncommitted changes detected"}\n'
import json, os
dirty_list = os.environ.get('CAST_DIRTY_LIST', '')
message = f"Uncommitted changes in: {dirty_list}. Commit before compacting (use commit agent)."
print(json.dumps({"decision": "block", "reason": message}))
PYEOF

# Log observability event
CAST_INPUT="$INPUT" python3 "${HOME}/.claude/scripts/cast-precompact-log.py" 2>/dev/null || true

exit 0
