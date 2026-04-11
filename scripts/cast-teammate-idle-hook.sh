#!/bin/bash
# cast-teammate-idle-hook.sh — TeammateIdle hook
# Fired when an agent team teammate goes idle.
# Exit 0 = done (acceptable output). Exit 2 = send feedback to keep working.
# Writes idle events to teammate_messages; no ad-hoc table creation.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# Parse fields from JSON input
AGENT_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agent_name', d.get('agent_id', 'unknown')))" 2>/dev/null || echo "unknown")
TASK_ID_VAL=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('task_id', ''))" 2>/dev/null || echo "")
RESULT=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null || echo "")

# Check for empty result
if [ -z "$RESULT" ]; then
  DB_PATH_VAL="$DB_PATH" AGENT_VAL="$AGENT_NAME" TASK_VAL="$TASK_ID_VAL" \
  python3 - <<'PYEOF' || true
import json, os, sqlite3, uuid
from datetime import datetime, timezone

db_path    = os.environ.get("DB_PATH_VAL", "")
agent_name = os.environ.get("AGENT_VAL", "unknown")
task_id    = os.environ.get("TASK_VAL", "")
iso_ts     = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if db_path and os.path.exists(db_path):
    try:
        con = sqlite3.connect(db_path, timeout=3)
        cur = con.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_messages'")
        if cur.fetchone():
            cur.execute(
                '''INSERT INTO teammate_messages
                   (id, swarm_id, from_agent, to_agent, message_type, payload, timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?)''',
                (str(uuid.uuid4())[:16], None, agent_name, None, "idle_event",
                 json.dumps({"task_id": task_id, "reason": "empty_result"}), iso_ts)
            )
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_runs'")
        if cur.fetchone() and task_id:
            cur.execute(
                "UPDATE teammate_runs SET status='idle' WHERE task_id=? AND status!='done'",
                (task_id,)
            )
        con.commit()
        con.close()
    except Exception:
        pass
PYEOF

  echo '{"feedback": "Your task produced no output. Please complete the assigned work before going idle. Review your task description and produce the required artifacts."}'
  exit 2
fi

# Check for placeholder/incomplete markers
if echo "$RESULT" | grep -qiE '(TODO|FIXME|PLACEHOLDER|NOT IMPLEMENTED|to be implemented)'; then
  DB_PATH_VAL="$DB_PATH" AGENT_VAL="$AGENT_NAME" TASK_VAL="$TASK_ID_VAL" \
  python3 - <<'PYEOF' || true
import json, os, sqlite3, uuid
from datetime import datetime, timezone

db_path    = os.environ.get("DB_PATH_VAL", "")
agent_name = os.environ.get("AGENT_VAL", "unknown")
task_id    = os.environ.get("TASK_VAL", "")
iso_ts     = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if db_path and os.path.exists(db_path):
    try:
        con = sqlite3.connect(db_path, timeout=3)
        cur = con.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_messages'")
        if cur.fetchone():
            cur.execute(
                '''INSERT INTO teammate_messages
                   (id, swarm_id, from_agent, to_agent, message_type, payload, timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?)''',
                (str(uuid.uuid4())[:16], None, agent_name, None, "idle_event",
                 json.dumps({"task_id": task_id, "reason": "placeholder_markers"}), iso_ts)
            )
        con.commit()
        con.close()
    except Exception:
        pass
PYEOF

  echo '{"feedback": "Your output contains TODO or placeholder markers. Please complete the implementation before going idle."}'
  exit 2
fi

# Valid output — log success event and exit 0
DB_PATH_VAL="$DB_PATH" AGENT_VAL="$AGENT_NAME" TASK_VAL="$TASK_ID_VAL" \
python3 - <<'PYEOF' || true
import json, os, sqlite3, uuid
from datetime import datetime, timezone

db_path    = os.environ.get("DB_PATH_VAL", "")
agent_name = os.environ.get("AGENT_VAL", "unknown")
task_id    = os.environ.get("TASK_VAL", "")
iso_ts     = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if db_path and os.path.exists(db_path):
    try:
        con = sqlite3.connect(db_path, timeout=3)
        cur = con.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_messages'")
        if cur.fetchone():
            cur.execute(
                '''INSERT INTO teammate_messages
                   (id, swarm_id, from_agent, to_agent, message_type, payload, timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?)''',
                (str(uuid.uuid4())[:16], None, agent_name, None, "idle_event",
                 json.dumps({"task_id": task_id, "reason": "output_validated"}), iso_ts)
            )
        con.commit()
        con.close()
    except Exception:
        pass
PYEOF

echo "{\"hookSpecificOutput\": {\"level\": \"debug\", \"message\": \"Teammate ${AGENT_NAME} idle — output validated\"}}"
exit 0
