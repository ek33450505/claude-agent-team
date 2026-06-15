#!/usr/bin/env python3
"""cast-precompact-log.py — observability logging for PreCompact events.
Reads CAST_INPUT env var (JSON), writes compaction_events to cast.db.
Exits 0 always, logs all failures to hook_failures table.
"""

import json
import os
import sys
import uuid
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

trigger = data.get("trigger", "unknown")
session_id = data.get("session_id", "unknown")

now = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Write to cast.db (best-effort, errors logged to hook_failures)
try:
    sys.path.insert(0, os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts')))
    from cast_db import db_execute, db_write, log_hook_failure

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
        'transcript_path': data.get('transcript_path', ''),
    })
except Exception as e:
    try:
        sys.path.insert(0, os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts')))
        from cast_db import log_hook_failure
        log_hook_failure('cast-precompact-log.py:compaction_events', 1, str(e), session_id)
    except Exception:
        pass  # Fallback: silently fail, hook must not crash

sys.exit(0)
