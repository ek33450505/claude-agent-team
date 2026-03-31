#\!/usr/bin/env python3
"""
cast-agent-run-log.py — Sub-agent run visibility helper for CAST orchestrator.
Reads a JSON payload from stdin and emits synthetic agent_runs rows into cast.db.

Operations:
  start  — INSERT a 'running' row when an agent is dispatched
  finish — UPDATE the row to final status when the agent returns

Input JSON fields:
  operation    : "start" or "finish"
  agent        : agent type string (e.g. "code-writer")
  agent_id     : unique correlation ID (e.g. "{session_id}-{batch_id}-{agent_type}")
  session_id   : parent session ID
  batch_id     : integer batch number
  task_summary : brief description (max 200 chars)
  model        : (optional) model string
  status       : (finish only) DONE | BLOCKED | DONE_WITH_CONCERNS

Exit codes:
  0 — always (never block the orchestrator)
"""
import sys, json, os, sqlite3
from datetime import datetime, timezone

def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def main():
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit(0)

    try:
        payload = json.loads(raw)
    except Exception:
        sys.exit(0)

    operation = payload.get('operation', '')
    if operation not in ('start', 'finish'):
        sys.exit(0)

    db_path = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
    if not os.path.exists(db_path):
        sys.exit(0)

    try:
        conn = sqlite3.connect(db_path, timeout=3)
        cur  = conn.cursor()

        if operation == 'start':
            agent       = payload.get('agent', 'unknown')
            agent_id    = payload.get('agent_id', '')
            session_id  = payload.get('session_id', '')
            batch_id    = payload.get('batch_id', 0)
            task_summary = (payload.get('task_summary') or '')[:200]
            model       = payload.get('model') or None
            project     = os.path.basename(os.getcwd()) or None

            cur.execute(
                '''INSERT INTO agent_runs
                   (session_id, agent, model, started_at, status, task_summary, agent_id, project)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
                (
                    session_id,
                    agent,
                    model,
                    now_iso(),
                    'running',
                    f"[batch-{batch_id}] {task_summary}",
                    agent_id,
                    project,
                )
            )

        elif operation == 'finish':
            agent_id  = payload.get('agent_id', '')
            status    = payload.get('status', 'DONE')
            if status not in ('DONE', 'BLOCKED', 'DONE_WITH_CONCERNS'):
                status = 'DONE'

            if agent_id:
                cur.execute(
                    '''UPDATE agent_runs
                       SET status=?, ended_at=?
                       WHERE agent_id=? AND status='running' ''',
                    (status, now_iso(), agent_id)
                )
            # If no agent_id provided, nothing to update — avoid ambiguous updates

        conn.commit()
        conn.close()

    except Exception:
        pass

main()
