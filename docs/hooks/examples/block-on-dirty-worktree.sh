#!/usr/bin/env bash
# block-on-dirty-worktree.sh — PreToolUse hook on Write/Edit
#
# Hook event: PreToolUse
# Fires before Write or Edit tool calls. If the current git working tree has
# untracked or modified files, exits 2 to block the write and explain why.
#
# This prevents Claude from writing new files on top of uncommitted changes,
# which is a common cause of lost work in multi-agent sessions.
#
# Stdin JSON fields used:
#   tool_name — "Write" or "Edit"
#   session_id — current session ID
#
# Exit codes:
#   0 — no dirty files found, or not inside a git repo; allow the write
#   2 — dirty worktree detected; block the write

# Guard: exit immediately inside subagent subprocess context
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# Error logger
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}

# Read stdin — Claude Code delivers the PreToolUse JSON here
INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Extract tool_name via Python env-var pattern (avoids injection)
export CAST_PRETOOL_INPUT="$INPUT"
TOOL_NAME="$(python3 -c "
import json, os, sys
raw = os.environ.get('CAST_PRETOOL_INPUT', '')
try:
    d = json.loads(raw)
    print(d.get('tool_name', ''))
except Exception:
    print('')
" 2>/dev/null || true)"

# Only apply this guard to Write and Edit tool calls
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

# Skip if not inside a git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Check for untracked or modified files
DIRTY="$(git status --porcelain 2>/dev/null || true)"

if [ -n "$DIRTY" ]; then
  # Return structured feedback; Claude Code surfaces this as the block reason
  printf '{"hookSpecificOutput":{"reason":"Dirty worktree — commit or stash changes before writing new files.","dirty_files":"%s"}}' \
    "$(echo "$DIRTY" | head -5 | tr '\n' ';')"
  exit 2
fi

# Clean worktree — allow the write
exit 0
