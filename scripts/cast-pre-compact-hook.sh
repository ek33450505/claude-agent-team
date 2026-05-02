#!/bin/bash
# cast-pre-compact-hook.sh — PreCompact hook (Claude Code)
# Logs pre-compaction event to cast.db and warns about context pressure.
# Always exits 0 — PreCompact is observability-only.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
# shellcheck disable=SC2329
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

INPUT="$(cat 2>/dev/null || true)"

# Touch marker for dashboard hook health
mkdir -p "${HOME}/.claude/cast/hook-last-fired" 2>/dev/null || true
touch "${HOME}/.claude/cast/hook-last-fired/cast-pre-compact.timestamp" 2>/dev/null || true

# Warn on stderr
echo "CAST: context compaction imminent — consider /compact or /clear" >&2

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || true
import json, os, uuid
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

trigger    = data.get("trigger", "unknown")
session_id = data.get("session_id", "unknown")

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Write to cast.db (best-effort)
import sys
sys.path.insert(0, os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts')))
try:
    from cast_db import db_execute, db_write
    db_execute('''
        CREATE TABLE IF NOT EXISTS compaction_events (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            timestamp TEXT,
            trigger TEXT,
            compaction_tier TEXT,
            transcript_path TEXT
        )
    ''')
    db_write('compaction_events', {
        'id': str(uuid.uuid4()),
        'session_id': session_id,
        'timestamp': iso_ts,
        'trigger': trigger,
        'compaction_tier': 'PreCompact',
        'transcript_path': '',
    })
except Exception:
    pass
PYEOF

# Block-on-dirty: check for staged or unstaged changes in current working directory
# Skip if not in a git repo (graceful pass-through).
# Set CAST_ALLOW_DIRTY_COMPACT=1 to bypass (audit-logged to cast.db).
if [[ "${CAST_ALLOW_DIRTY_COMPACT:-0}" == "1" ]]; then
  # Audit-log bypass to cast.db so it's traceable, then continue.
  bash ~/.claude/scripts/cast-events.sh log "precompact_bypass" "CAST_ALLOW_DIRTY_COMPACT=1" 2>/dev/null || true
  # Skip the dirty-tree block; proceed with normal pre-compact flow.
else
  if git rev-parse --git-dir > /dev/null 2>&1; then
      # Check for staged changes
      if ! git diff --staged --quiet 2>/dev/null; then
          echo '{"hookSpecificOutput":{"hookEventName":"PreCompact","decision":"block","reason":"Uncommitted session work (staged) — run /commit before /compact."}}' >&2
          exit 2
      fi

      # Check for unstaged changes (attribute to current session)
      if ! git diff --quiet 2>/dev/null; then
          echo '{"hookSpecificOutput":{"hookEventName":"PreCompact","decision":"block","reason":"Uncommitted session work (unstaged) — run /commit before /compact."}}' >&2
          exit 2
      fi
  fi
fi

exit 0
