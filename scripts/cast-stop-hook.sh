#!/bin/bash
# cast-stop-hook.sh — Stop hook (uncommitted changes reminder)
# Fires when a Claude Code session is stopping.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Check for uncommitted changes
#   3. Emit reminder via hookSpecificOutput if dirty
#
# Stdin JSON fields (Stop):
#   session_id — current session
#   cwd        — working directory
#
# Exit codes:
#   0 — always (hook must not block)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Extract cwd from input JSON
CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

# Fall back to current directory
if [ -z "$CWD" ]; then
    CWD="$(pwd)"
fi

# Check if we're in a git repo
if [ ! -d "$CWD/.git" ] && ! git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

# Check for uncommitted changes
DIRTY=$(git -C "$CWD" status --porcelain 2>/dev/null || true)

if [ -n "$DIRTY" ]; then
    FILE_COUNT=$(echo "$DIRTY" | wc -l | tr -d ' ')
    cat <<JSONEOF
{
  "hookSpecificOutput": {
    "level": "warn",
    "message": "Uncommitted changes detected (${FILE_COUNT} files) — consider running /commit before ending session."
  }
}
JSONEOF
fi

exit 0
