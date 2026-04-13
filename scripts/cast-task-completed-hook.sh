#!/bin/bash
# cast-task-completed-hook.sh — CAST TaskCompleted hook
# Hook event: TaskCompleted (Agent Teams)
#
# Fires when a task in an Agent Team's shared task list is marked completed.
# Logs task completions to cast.db and emits a CAST event for observability.
#
# Stdin JSON fields (TaskCompleted):
#   task_id         — ID of the completed task
#   task_subject    — subject/title of the completed task
#   completed_by    — teammate name/ID that completed it
#   session_id      — team session ID
#
# Exit codes:
#   0 — always (async hook, must not block)

# Subprocess guard — skip if running inside a subagent
[[ "${CLAUDE_SUBPROCESS:-}" == "1" ]] && exit 0

set -euo pipefail

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
LOG_FILE="${HOME}/.claude/logs/task-completed.log"

mkdir -p "$EVENTS_DIR" "${HOME}/.claude/logs" 2>/dev/null || true

# Read stdin once
INPUT="$(cat 2>/dev/null || true)"
if [[ -z "$INPUT" ]]; then
  exit 0
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")"
TIMESTAMP_FILE="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "unknown")"

# Parse JSON fields via env var
export CAST_TC_INPUT="$INPUT"

PARSED="$(python3 - <<'PYEOF' 2>/dev/null || echo '{}'
import json, os

raw = os.environ.get('CAST_TC_INPUT', '')
if not raw:
    print('{}')
    raise SystemExit(0)

try:
    data = json.loads(raw)
except Exception:
    print('{}')
    raise SystemExit(0)

result = {
    "task_id":      data.get("task_id", data.get("taskId", "")),
    "task_subject": data.get("task_subject", data.get("subject", "")),
    "completed_by": data.get("completed_by", data.get("agent_type", "unknown")),
    "session_id":   data.get("session_id", ""),
}
print(json.dumps(result))
PYEOF
)"

export CAST_TC_PARSED="$PARSED"

TASK_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_TC_PARSED','{}')); print(d.get('task_id',''))" 2>/dev/null || echo "")"
TASK_SUBJECT="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_TC_PARSED','{}')); print(d.get('task_subject',''))" 2>/dev/null || echo "")"
COMPLETED_BY="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_TC_PARSED','{}')); print(d.get('completed_by','unknown'))" 2>/dev/null || echo "unknown")"
SESSION_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_TC_PARSED','{}')); print(d.get('session_id',''))" 2>/dev/null || echo "")"

# ── Step 1: Write event to ~/.claude/cast/events/ ──────────────────────────────
SAFE_BY="${COMPLETED_BY//[^a-zA-Z0-9_-]/}"
EVENT_FILE="${EVENTS_DIR}/${TIMESTAMP_FILE}-${SAFE_BY}-task-completed.json"

export CAST_TC_EVENT_FILE="$EVENT_FILE"
export CAST_TC_TASK_ID="$TASK_ID"
export CAST_TC_SUBJECT="$TASK_SUBJECT"
export CAST_TC_BY="$COMPLETED_BY"
export CAST_TC_SESSION="$SESSION_ID"
export CAST_TC_TS="$TIMESTAMP"

python3 - <<'PYEOF' 2>/dev/null || true
import json, os

event = {
    "event_id":      'task-completed-' + os.environ.get('CAST_TC_TASK_ID','') + '-' + os.environ.get('CAST_TC_TS',''),
    "timestamp":     os.environ.get('CAST_TC_TS',''),
    "event_type":    "task_completed",
    "task_id":       os.environ.get('CAST_TC_TASK_ID',''),
    "task_subject":  os.environ.get('CAST_TC_SUBJECT',''),
    "completed_by":  os.environ.get('CAST_TC_BY','unknown'),
    "session_id":    os.environ.get('CAST_TC_SESSION',''),
    "source":        "TaskCompleted",
}

filepath = os.environ.get('CAST_TC_EVENT_FILE','')
if filepath:
    with open(filepath, 'w') as f:
        json.dump(event, f, indent=2)
PYEOF

# ── Step 2: Log to cast.db if available ─────────────────────────────────────────
if [[ -f "$DB_PATH" ]] && command -v python3 >/dev/null 2>&1; then
  export CAST_TC_DB="$DB_PATH"
  python3 - <<'PYEOF' 2>/dev/null || true
import sys, os
sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
try:
    from cast_db import db_write, db_execute
    import datetime

    db_execute('''
        CREATE TABLE IF NOT EXISTS team_task_completions (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            task_id TEXT,
            task_subject TEXT,
            completed_by TEXT,
            timestamp TEXT
        )
    ''')

    db_write('team_task_completions', {
        'id': os.urandom(8).hex(),
        'session_id': os.environ.get('CAST_TC_SESSION', ''),
        'task_id': os.environ.get('CAST_TC_TASK_ID', ''),
        'task_subject': os.environ.get('CAST_TC_SUBJECT', ''),
        'completed_by': os.environ.get('CAST_TC_BY', 'unknown'),
        'timestamp': os.environ.get('CAST_TC_TS', datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')),
    })
except Exception:
    pass
PYEOF
fi

# ── Step 3: Append to log ──────────────────────────────────────────────────────
echo "${TIMESTAMP} task_completed task=${TASK_ID} by=${COMPLETED_BY} subject='${TASK_SUBJECT}'" >> "$LOG_FILE" 2>/dev/null || true

# ── Step 4: Emit event via cast-events.sh if available ──────────────────────────
if [[ -f "${HOME}/.claude/scripts/cast-events.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.claude/scripts/cast-events.sh" 2>/dev/null || true
  cast_emit_event 'task_completed' "$COMPLETED_BY" "task-${TASK_ID}" '' \
    "Task '${TASK_SUBJECT}' completed by ${COMPLETED_BY}" \
    'DONE' 2>/dev/null || true
fi

exit 0
