#!/bin/bash
# cast-task-completed-hook.sh — TaskCompleted hook (Claude Code v2.1.84+)
# Logs background agent task completion events to cast/events/ and cast.db.
# Checks active plan's ADM for pending next batch and logs to pipeline.log.
# Always exits 0 — never blocks task completion.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

CAST_INPUT="$INPUT" DB_PATH_VAL="$DB_PATH" python3 - <<'PYEOF' || true
import json, os, sqlite3, uuid, glob
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
    "type":         "task_completed",
    "task_id":      task_id,
    "task_subject": task_subject,
    "session_id":   session_id,
    "project":      project,
}
short_id   = str(uuid.uuid4())[:8]
event_path = os.path.join(events_dir, f"{iso_ts}-{short_id}-task-completed.json")
try:
    with open(event_path, "w") as f:
        json.dump(event, f, indent=2)
        f.write("\n")
except Exception:
    pass

# Log to cast.db agent_runs if the DB and table exist
if db_path and os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path)
        cur  = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='agent_runs'")
        if cur.fetchone():
            cur.execute('''
                INSERT INTO agent_runs
                  (started_at, project, agent, task, status)
                VALUES (?, ?, ?, ?, ?)
            ''', (iso_ts, project, "background", task_subject or task_id, "completed"))
            conn.commit()
        conn.close()
    except Exception:
        pass

# Check active plan's ADM for pending next batch — log to pipeline.log
pipeline_log = os.path.expanduser("~/.claude/logs/pipeline.log")
os.makedirs(os.path.dirname(pipeline_log), exist_ok=True)

# Find the most recently modified plan file as active plan candidate
plans_dir = os.path.expanduser("~/.claude/plans")
active_plan = None
if os.path.isdir(plans_dir):
    plan_files = sorted(glob.glob(os.path.join(plans_dir, "*.md")), key=os.path.getmtime, reverse=True)
    if plan_files:
        active_plan = plan_files[0]

if active_plan:
    try:
        with open(active_plan) as f:
            plan_content = f.read()
        # Check for ADM dispatch block
        if '"batches"' in plan_content:
            try:
                with open(pipeline_log, "a") as f:
                    f.write(f"[{iso_ts}] task_completed: {task_subject or task_id} | session: {session_id} | plan: {active_plan}\n")
            except Exception:
                pass
    except Exception:
        pass
PYEOF

exit 0
