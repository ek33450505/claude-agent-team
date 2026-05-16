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

CAST_INPUT="$INPUT" python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import json, os, uuid, sys
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

trigger    = data.get("trigger", "unknown")
session_id = data.get("session_id", "unknown")

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Write to cast.db (best-effort, errors logged to hook_failures)
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
except Exception as e:
    try:
        from cast_db import log_hook_failure
        log_hook_failure('cast-pre-compact-hook.sh:compaction_events', 1, str(e), session_id)
    except Exception:
        pass  # Fallback: silently fail, hook must not crash
PYEOF

# Block-on-dirty: check for staged or unstaged changes in current working directory
# Skip if not in a git repo (graceful pass-through).
# Set CAST_ALLOW_DIRTY_COMPACT=1 to bypass (audit-logged to cast.db).
if [[ "${CAST_ALLOW_DIRTY_COMPACT:-0}" == "1" ]]; then
  # Log bypass event to cast.db for audit trail.
  python3 - <<'PYEOF' 2>/dev/null || true
import os, sqlite3
from datetime import datetime, timezone
db_path = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
try:
    conn = sqlite3.connect(os.path.expanduser(db_path), timeout=5)
    conn.execute(
        "INSERT INTO routing_events (session_id, event_type, data, timestamp) VALUES (?, ?, ?, ?)",
        (os.environ.get('CLAUDE_SESSION_ID', 'unknown'), 'dirty_compact_bypass',
         'CAST_ALLOW_DIRTY_COMPACT=1 set; dirty check skipped', datetime.now(timezone.utc).isoformat())
    )
    conn.commit()
    conn.close()
except Exception:
    pass
PYEOF
  exit 0
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
