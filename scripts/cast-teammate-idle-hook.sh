#!/usr/bin/env bash
# CAST TeammateIdle hook
# Fired when an agent team teammate goes idle.
# Exit 0 = done (acceptable). Exit 2 = send feedback to keep working.

set -euo pipefail

INPUT=$(cat)

# Check if teammate produced any output
RESULT=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null || echo "")

# Helper: emit event to cast.db (best-effort, never fail)
_emit_idle_event() {
  local event_type="$1"
  local reason="${2:-}"
  if [ -f "${HOME}/.claude/scripts/cast-events.sh" ]; then
    # shellcheck source=/dev/null
    source "${HOME}/.claude/scripts/cast-events.sh" 2>/dev/null || true
    if declare -f cast_emit_event >/dev/null 2>&1; then
      cast_emit_event "$event_type" "{\"agent\":\"teammate\",\"reason\":\"${reason}\"}" 2>/dev/null || true
    fi
  fi
}

# Log idle event to cast.db
AGENT_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agent_name', d.get('agent_id', 'unknown')))" 2>/dev/null || echo "unknown")
TASK_ID_VAL=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('task_id', ''))" 2>/dev/null || echo "")

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
if [ -f "$DB_PATH" ]; then
  python3 -c "
import sqlite3, os
from datetime import datetime, timezone
db = os.environ.get('DB_PATH', os.path.expanduser('~/.claude/cast.db'))
try:
    con = sqlite3.connect(db, timeout=3)
    con.execute('''CREATE TABLE IF NOT EXISTS teammate_idle_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT, agent_name TEXT, task_id TEXT, had_result INTEGER
    )''')
    con.execute('INSERT INTO teammate_idle_events (timestamp, agent_name, task_id, had_result) VALUES (?, ?, ?, ?)',
        (datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), '$AGENT_NAME', '$TASK_ID_VAL', 0 if not '$RESULT' else 1))
    con.commit(); con.close()
except Exception:
    pass
" 2>/dev/null || true
fi

if [ -z "$RESULT" ]; then
  _emit_idle_event "teammate_idle_block" "empty_result" || true

  # Check if this is a critical orchestrator batch task
  CHECKPOINT_FILES=$(ls "${HOME}/.claude/cast/orchestrator-checkpoint-"*.log 2>/dev/null | head -1 || true)
  if [ -n "$CHECKPOINT_FILES" ]; then
    _emit_idle_event "teammate_idle_block_critical" "empty_result_in_orchestrator_batch" || true
  fi

  echo '{"feedback": "Your task produced no output. Please complete the assigned work before going idle. Review your task description and produce the required artifacts."}'
  exit 2
fi

# Check for placeholder/incomplete markers
if echo "$RESULT" | grep -qiE '(TODO|FIXME|PLACEHOLDER|NOT IMPLEMENTED|to be implemented)'; then
  _emit_idle_event "teammate_idle_block" "placeholder_markers" || true
  echo '{"feedback": "Your output contains TODO or placeholder markers. Please complete the implementation before going idle."}'
  exit 2
fi

_emit_idle_event "teammate_idle_pass" "" || true
exit 0
