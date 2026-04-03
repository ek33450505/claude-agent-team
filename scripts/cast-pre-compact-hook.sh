#!/bin/bash
# cast-pre-compact-hook.sh — PreCompact hook (Claude Code)
# Logs pre-compaction event to cast.db and warns about context pressure.
# Always exits 0 — PreCompact is observability-only.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

# Touch marker for dashboard hook health
mkdir -p "${HOME}/.claude/cast/hook-last-fired"
touch "${HOME}/.claude/cast/hook-last-fired/cast-pre-compact.timestamp"

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
sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
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

exit 0
