#!/bin/bash
# cast-task-created-hook.sh — TaskCreated hook (Claude Code v2.1.84+)
# Logs background agent task creation events to cast/events/ and cast.db.
# Always exits 0 — never blocks task creation.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

CAST_INPUT="$INPUT" DB_PATH_VAL="$DB_PATH" python3 - <<'PYEOF' || true
import json, os, sqlite3, uuid
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
db_path = os.environ.get("DB_PATH_VAL", "")

try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

task_id      = data.get("task_id", "")
task_subject = (data.get("task_subject") or data.get("task_description") or "")[:80]
session_id   = data.get("session_id", "unknown")
cwd          = data.get("cwd", "")
project      = os.path.basename(cwd) if cwd else ""

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Write to cast/events/
events_dir = os.path.expanduser("~/.claude/cast/events")
os.makedirs(events_dir, exist_ok=True)
event = {
    "id":           str(uuid.uuid4()),
    "timestamp":    iso_ts,
    "type":         "task_created",
    "task_id":      task_id,
    "task_subject": task_subject,
    "session_id":   session_id,
    "project":      project,
}
short_id   = str(uuid.uuid4())[:8]
event_path = os.path.join(events_dir, f"{iso_ts}-{short_id}-task-created.json")
try:
    with open(event_path, "w") as f:
        json.dump(event, f, indent=2)
        f.write("\n")
except Exception:
    pass

# Log to cast.db task_queue if the DB and table exist
if db_path and os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path)
        cur  = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='task_queue'")
        if cur.fetchone():
            cur.execute('''
                INSERT INTO task_queue
                  (created_at, project, project_root, agent, task, status)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (iso_ts, project, cwd, "background", task_subject or task_id, "running"))
            conn.commit()
        conn.close()
    except Exception:
        pass
PYEOF

exit 0
