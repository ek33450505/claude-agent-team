#!/bin/bash
# cast-proactive-intel.sh — SessionStart hook that surfaces unverified user_profile patterns
#
# Fires on UserPromptSubmit (session start) and queries agent_memories for user_profile
# facts that haven't been verified in 30+ days. Surfaces 1-2 advisory lines to stderr.
#
# Non-blocking: always exits 0. No hookSpecificOutput — just stderr advisory.
#
# Usage:
#   Called by system hook on UserPromptSubmit event
#   Can also be invoked manually: bash scripts/cast-proactive-intel.sh
#
# Output: advisory lines to stderr, max 2 lines

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# If DB doesn't exist or is empty, exit gracefully
if [ ! -f "$DB_PATH" ]; then
  exit 0
fi

# Query for unverified or stale user_profile facts
# Look for entries where created_at is > 30 days old
# (We use created_at as a proxy for "not recently surfaced" since we don't have last_verified tracking yet)

STALE_COUNT=$(sqlite3 "$DB_PATH" \
  "SELECT COUNT(*) FROM agent_memories
   WHERE type='user_profile' AND agent='global'
   AND created_at < datetime('now', '-30 days');" 2>/dev/null || echo "0")

# Also check for unreviewed patterns in project-scoped feedback/reference
PROJECT_UNREVIEWED=$(sqlite3 "$DB_PATH" \
  "SELECT COUNT(*) FROM agent_memories
   WHERE type IN ('feedback', 'reference')
   AND updated_at < datetime('now', '-30 days');" 2>/dev/null || echo "0")

# Surface advisory if there are patterns needing attention
if [ "$STALE_COUNT" -gt 0 ]; then
  echo "[CAST] Proactive: $STALE_COUNT user profile patterns haven't been reviewed in 30+ days." >&2
fi

if [ "$PROJECT_UNREVIEWED" -gt 5 ]; then
  echo "[CAST] Proactive: $PROJECT_UNREVIEWED project insights may have drifted — consider a memory verify sweep." >&2
fi

exit 0
