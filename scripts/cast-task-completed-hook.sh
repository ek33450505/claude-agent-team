#!/bin/bash
# cast-task-completed-hook.sh — TaskCompleted hook (Claude Code v2.1.84+)
# Logs background agent task completion events to cast/events/ and cast.db.
# Updates teammate_runs status and inserts into teammate_messages for swarm tracking.
# Always exits 0 — never blocks task completion.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

CAST_INPUT="$INPUT" DB_PATH_VAL="$DB_PATH" python3 - <<'PYEOF' || true
import json, os, sqlite3, uuid, glob, re
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
db_path = os.environ.get("DB_PATH_VAL", "")

try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

task_id       = data.get("task_id", "")
task_subject  = (data.get("task_subject") or data.get("task_description") or "")[:80]
task_result   = data.get("result", data.get("task_result", ""))
session_id    = data.get("session_id", "unknown")
agent_name    = data.get("agent_name", "background")
cwd           = data.get("cwd", "")
project       = os.path.basename(cwd) if cwd else ""

# Verify Status block in task result (CAST contract)
status_match     = re.search(r'Status:\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)', str(task_result))
has_status_block = bool(status_match)
extracted_status = status_match.group(1) if status_match else "MISSING"

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
    "agent_name":   agent_name,
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

if not (db_path and os.path.exists(db_path)):
    print(json.dumps({"hookSpecificOutput": {"level": "info", "message": f"Task {task_id} completed by {agent_name}"}}))
    import sys; sys.exit(0)

try:
    conn = sqlite3.connect(db_path, timeout=3)
    cur  = conn.cursor()

    # Update teammate_runs row: set status='done', ended_at
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_runs'")
    if cur.fetchone() and task_id:
        cur.execute(
            "UPDATE teammate_runs SET status='done', ended_at=? WHERE task_id=?",
            (iso_ts, task_id)
        )

    # Insert into teammate_messages (task_completed event)
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_messages'")
    if cur.fetchone():
        swarm_id = None
        if task_id:
            cur.execute("SELECT swarm_id FROM teammate_runs WHERE task_id=? LIMIT 1", (task_id,))
            row = cur.fetchone()
            if row:
                swarm_id = row[0]
        cur.execute(
            '''INSERT INTO teammate_messages
               (id, swarm_id, from_agent, to_agent, message_type, payload, timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?)''',
            (
                str(uuid.uuid4())[:16],
                swarm_id,
                agent_name,
                None,
                "task_completed",
                json.dumps({"task_id": task_id, "task_subject": task_subject, "status": extracted_status}),
                iso_ts,
            )
        )

    # Log to agent_runs
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='agent_runs'")
    if cur.fetchone():
        cur.execute(
            "INSERT INTO agent_runs (started_at, project, agent, task_summary, status) VALUES (?, ?, ?, ?, ?)",
            (iso_ts, project, agent_name, task_subject or task_id, "DONE")
        )

    # Log Status block compliance
    cur.execute('''
        CREATE TABLE IF NOT EXISTS quality_gates (
            id TEXT PRIMARY KEY, session_id TEXT, batch_id INTEGER, agent_name TEXT,
            timestamp TEXT, status_line TEXT, contract_passed INTEGER, retry_count INTEGER
        )
    ''')
    cur.execute(
        '''INSERT INTO quality_gates
           (id, session_id, batch_id, agent_name, timestamp, status_line, contract_passed, retry_count)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        (str(uuid.uuid4())[:16], session_id, 0, agent_name, iso_ts,
         f"Status: {extracted_status}", 1 if has_status_block else 0, 0)
    )

    conn.commit()
    conn.close()
except Exception:
    pass

# Log to pipeline.log if an active plan with ADM is found
pipeline_log = os.path.expanduser("~/.claude/logs/pipeline.log")
os.makedirs(os.path.dirname(pipeline_log), exist_ok=True)
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
        if '"batches"' in plan_content:
            with open(pipeline_log, "a") as f:
                f.write(f"[{iso_ts}] task_completed: {task_subject or task_id} | agent: {agent_name} | session: {session_id} | plan: {active_plan}\n")
    except Exception:
        pass

print(json.dumps({"hookSpecificOutput": {"level": "info", "message": f"Task {task_id} completed by {agent_name}"}}))
PYEOF

exit 0
