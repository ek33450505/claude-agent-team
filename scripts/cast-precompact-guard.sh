#!/bin/bash
# cast-precompact-guard.sh — PreCompact hook: block compaction if any tracked repo is dirty
# Returns {"decision":"block","reason":"..."} to stdout when dirty repos found.
# Returns {"decision":"allow"} when clean.
# Exit 0 always.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

INPUT="$(cat 2>/dev/null || true)"

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
    "SELECT DISTINCT project_root FROM sessions WHERE started_at > datetime('now','-1 day') AND project_root IS NOT NULL AND project_root != '' LIMIT 20;" \
    2>/dev/null || true)
fi

DIRTY_REPOS=()

for proj in "${KNOWN_PROJECTS[@]}"; do
  # Defensive: reject paths starting with '-' so git -C can't reinterpret as an option
  case "$proj" in -*) continue ;; esac
  [ -d "$proj/.git" ] || continue
  STATUS="$(git -C "$proj" status --porcelain 2>/dev/null || true)"
  if [ -n "$STATUS" ]; then
    DIRTY_REPOS+=("$proj")
  fi
done

# Deduplicate
DIRTY_REPOS=($(printf '%s\n' "${DIRTY_REPOS[@]}" | sort -u))

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
