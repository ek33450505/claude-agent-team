#!/bin/bash
# cast-subagent-start-hook.sh — CAST SubagentStart hook
# Hook event: SubagentStart
#
# Fires when a subagent is spawned via the Agent tool.
# Responsibilities:
#   1. Emit task_claimed event to ~/.claude/cast/events/
#   2. Mirror to cast.db agent_runs table (INSERT running row)
#
# Stdin JSON fields (SubagentStart):
#   agent_name  — name of the subagent being spawned
#   session_id  — parent session ID
#   agent_id    — unique ID for this subagent invocation (may be absent)
#
# Exit codes:
#   0 — always (hook must not block the parent session)
#
# Cron / installation note:
#   Wired in ~/.claude/settings.json under "SubagentStart" with async: true

# Never fail loudly — a broken hook must not interrupt the parent session.
set +e

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
START_ERROR_LOG="${HOME}/.claude/logs/subagent-start-errors.log"
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
mkdir -p "$EVENTS_DIR" 2>/dev/null || true

# _log_error: append a structured error line to hook-errors.log (never fails itself)
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

# Read stdin once
INPUT="$(cat 2>/dev/null)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse fields via env var (never interpolate into Python source)
export CAST_START_INPUT="$INPUT"

PARSED="$(python3 - <<'PYEOF' 2>/dev/null
import sys, json, os

raw = os.environ.get('CAST_START_INPUT', '')
if not raw:
    print(json.dumps({"error": "no input"}))
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print(json.dumps({"error": "invalid json"}))
    sys.exit(0)

result = {
    "agent_name": data.get("agent_type") or data.get("agent_name") or data.get("subagent_name") or "unknown",
    "session_id": data.get("session_id") or "",
    "agent_id":   data.get("agent_id") or data.get("subagent_id") or "",
}
print(json.dumps(result))
PYEOF
)" || true

if [ -z "$PARSED" ]; then
  exit 0
fi

# Extract fields
export CAST_START_PARSED="$PARSED"

AGENT_NAME="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_START_PARSED','{}')); print(d.get('agent_name','unknown'))" 2>/dev/null || echo "unknown")"
SESSION_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_START_PARSED','{}')); print(d.get('session_id',''))" 2>/dev/null || echo "")"
AGENT_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_START_PARSED','{}')); print(d.get('agent_id',''))" 2>/dev/null || echo "")"
export CAST_START_AGENT_ID="$AGENT_ID"

# ── Step 1: Write task_claimed event to ~/.claude/cast/events/ ────────────────
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))")"
TIMESTAMP_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())" | sed 's/+00:00/Z/')"
SAFE_AGENT="${AGENT_NAME//[^a-zA-Z0-9_-]/}"
EVENT_FILE="${EVENTS_DIR}/${TIMESTAMP}-${SAFE_AGENT}-subagent-start.json"

export CAST_START_AGENT="$AGENT_NAME"
export CAST_START_SESSION="$SESSION_ID"
export CAST_START_TS_ISO="$TIMESTAMP_ISO"
export CAST_START_EVENT_FILE="$EVENT_FILE"

python3 - <<'PYEOF' 2>/dev/null || true
import json, os

event = {
    "event_id":   os.environ.get('CAST_START_AGENT', 'unknown') + '-subagent-start-' + os.environ.get('CAST_START_TS_ISO', ''),
    "timestamp":  os.environ.get('CAST_START_TS_ISO', ''),
    "event_type": "task_claimed",
    "agent":      os.environ.get('CAST_START_AGENT', 'unknown'),
    "session_id": os.environ.get('CAST_START_SESSION', ''),
    "source":     "SubagentStart",
}

filepath = os.environ.get('CAST_START_EVENT_FILE', '')
if filepath:
    with open(filepath, 'w') as f:
        json.dump(event, f, indent=2)
PYEOF

# ── Step 2: Insert running row into cast.db agent_runs ────────────────────────
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  export CAST_START_DB_PATH="$DB_PATH"
  python3 - <<'PYEOF' 2>>"$START_ERROR_LOG" || true
import sqlite3, os, time

db       = os.path.expanduser(os.environ.get('CAST_START_DB_PATH', '~/.claude/cast.db'))
agent    = os.environ.get('CAST_START_AGENT', '')
sess     = os.environ.get('CAST_START_SESSION', '')
ts       = os.environ.get('CAST_START_TS_ISO', '')
agent_id = os.environ.get('CAST_START_AGENT_ID', '')
err_log  = os.path.expanduser('~/.claude/logs/hook-errors.log')

if not agent:
    raise SystemExit(0)

def _log_hook_error(msg):
    try:
        from datetime import datetime, timezone
        t = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(err_log, 'a') as f:
            f.write(f"[{t}] ERROR cast-subagent-start-hook.sh: {msg}\n")
    except Exception:
        pass

# H8: Retry up to 3 times with backoff on SQLITE_BUSY / locked
for attempt in range(3):
    try:
        conn = sqlite3.connect(db, timeout=5)
        cur  = conn.cursor()
        # Check if agent_runs has agent_id column
        cols = [r[1] for r in cur.execute("PRAGMA table_info(agent_runs)").fetchall()]
        if 'agent_id' in cols:
            cur.execute(
                "INSERT INTO agent_runs (agent, session_id, status, started_at, agent_id) VALUES (?, ?, 'running', ?, ?)",
                (agent, sess, ts, agent_id),
            )
        else:
            cur.execute(
                "INSERT INTO agent_runs (agent, session_id, status, started_at) VALUES (?, ?, 'running', ?)",
                (agent, sess, ts),
            )
        conn.commit()
        conn.close()
        break
    except sqlite3.OperationalError as e:
        conn_close_safe = locals().get('conn')
        if conn_close_safe:
            try: conn_close_safe.close()
            except Exception: pass
        if 'locked' in str(e) and attempt < 2:
            time.sleep(0.1 * (attempt + 1))
        else:
            _log_hook_error(f"DB INSERT failed after {attempt+1} attempt(s): {e}")
            break
    except Exception as e:
        _log_hook_error(f"DB INSERT unexpected error: {type(e).__name__}: {e}")
        break
PYEOF
fi

exit 0
