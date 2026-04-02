#!/bin/bash
# cast-post-compact-hook.sh — PostCompact hook (Claude Code v2.1.76+)
# Logs context compaction events to cast/events/ and compact-log.jsonl.
# Always exits 0 — PostCompact is observability-only (stdout ignored by Claude Code).

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

# Touch marker for dashboard hook health
mkdir -p "${HOME}/.claude/cast/hook-last-fired"
touch "${HOME}/.claude/cast/hook-last-fired/cast-post-compact.timestamp"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || true
import json, os, uuid
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

trigger         = data.get("trigger", "unknown")
session_id      = data.get("session_id", "unknown")
transcript_path = data.get("transcript_path", "")

# Map trigger to canonical compaction tier
# Claude Code PostCompact trigger values: 'auto', 'manual', 'micro' (confirmed from source)
def detect_tier(trigger_val):
    t = (trigger_val or "").lower()
    if t in ("micro", "microcompact"):
        return "MicroCompact"
    elif t in ("manual", "full", "user"):
        return "FullCompact"
    elif t in ("auto", "autocompact", ""):
        return "AutoCompact"
    else:
        return f"Unknown({trigger_val})"

compaction_tier = detect_tier(trigger)

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

event = {
    "id":               str(uuid.uuid4()),
    "timestamp":        iso_ts,
    "type":             "post_compact",
    "trigger":          trigger,
    "compaction_tier":  compaction_tier,
    "session_id":       session_id,
    "transcript_path":  transcript_path,
}

# Write to cast/events/
events_dir = os.path.expanduser("~/.claude/cast/events")
os.makedirs(events_dir, exist_ok=True)
short_id   = str(uuid.uuid4())[:8]
event_path = os.path.join(events_dir, f"{iso_ts}-{short_id}-compact.json")
try:
    with open(event_path, "w") as f:
        json.dump(event, f, indent=2)
        f.write("\n")
except Exception:
    pass

# Append to compact-log.jsonl for easy chronological review
log_path = os.path.expanduser("~/.claude/cast/compact-log.jsonl")
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(event) + "\n")
except Exception:
    pass

# Write compaction tier to cast.db (best-effort — hook must not fail)
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
        'id': event['id'],
        'session_id': session_id,
        'timestamp': iso_ts,
        'trigger': trigger,
        'compaction_tier': compaction_tier,
        'transcript_path': transcript_path,
    })
except Exception:
    pass
PYEOF

exit 0
