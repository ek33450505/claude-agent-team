#!/bin/bash
# cast-queue-add.sh — Enqueue a task into the CAST persistent task queue
#
# Usage:
#   cast-queue-add.sh <agent> "<task>" [--priority <1-10>] [--when "<ISO8601>"]
#
# Arguments:
#   <agent>       Name of the CAST agent (must have ~/.claude/agents/<agent>.md)
#   "<task>"      Task description string
#   --priority    Integer 1-10 (1=urgent, 10=low). Default: 5
#   --when        ISO8601 datetime string. Default: NULL (run immediately)
#
# Outputs: Inserted task ID on success
# Exit: 0 success, 1 validation error or insert failure
#
# Example:
#   cast-queue-add.sh code-reviewer "Review src/auth.js for security issues" --priority 3
#   cast-queue-add.sh morning-briefing "Daily standup brief" --when "2026-03-27T07:00:00"

set -euo pipefail

AGENTS_DIR="${HOME}/.claude/agents"
CAST_DB="${HOME}/.claude/cast.db"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<USAGE
Usage: $(basename "$0") <agent> "<task>" [--priority <1-10>] [--when "<ISO8601>"]

  <agent>       CAST agent name (must have ~/.claude/agents/<agent>.md)
  "<task>"      Task description
  --priority    1-10, where 1=urgent and 10=low (default: 5)
  --when        ISO8601 datetime for scheduled execution (default: run immediately)

Exit codes: 0 success, 1 error
USAGE
  exit 1
}

# ── Require at least 2 args ──────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  usage
fi

AGENT_NAME="$1"
TASK_TEXT="$2"
shift 2

# ── Parse optional flags ─────────────────────────────────────────────────────
PRIORITY=5
SCHEDULED_FOR=""  # empty = NULL = run immediately

while [[ $# -gt 0 ]]; do
  case "$1" in
    --priority)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --priority requires a value" >&2
        exit 1
      fi
      PRIORITY="$2"
      shift 2
      ;;
    --when)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --when requires a value" >&2
        exit 1
      fi
      SCHEDULED_FOR="$2"
      shift 2
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage
      ;;
  esac
done

# ── Validate agent name ──────────────────────────────────────────────────────
if [[ -z "$AGENT_NAME" ]]; then
  echo "Error: agent name is required" >&2
  exit 1
fi

AGENT_FILE="${AGENTS_DIR}/${AGENT_NAME}.md"
if [[ ! -f "$AGENT_FILE" ]]; then
  echo "Error: agent not found: ${AGENT_FILE}" >&2
  echo "       Run: ls ${AGENTS_DIR}/ to see available agents" >&2
  exit 1
fi

# ── Validate task text ───────────────────────────────────────────────────────
if [[ -z "$TASK_TEXT" ]]; then
  echo "Error: task text is required" >&2
  exit 1
fi

# ── Validate priority ────────────────────────────────────────────────────────
if ! [[ "$PRIORITY" =~ ^[0-9]+$ ]] || [[ "$PRIORITY" -lt 1 || "$PRIORITY" -gt 10 ]]; then
  echo "Error: --priority must be an integer between 1 and 10 (got: ${PRIORITY})" >&2
  exit 1
fi

# ── Validate --when format if provided ──────────────────────────────────────
if [[ -n "$SCHEDULED_FOR" ]]; then
  # Basic ISO8601 sanity check via Python
  VALID_DATE=$(python3 -c "
from datetime import datetime
import sys
try:
    # Accept various ISO8601 forms: with T, with space, with Z, with offset
    s = '${SCHEDULED_FOR}'.replace('Z', '+00:00')
    datetime.fromisoformat(s)
    print('ok')
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null || echo "error: python3 unavailable")
  if [[ "$VALID_DATE" != "ok" ]]; then
    echo "Error: --when value is not a valid ISO8601 datetime: ${SCHEDULED_FOR}" >&2
    echo "       Example: --when '2026-03-27T08:00:00'" >&2
    exit 1
  fi
fi

# ── Check cast.db exists ─────────────────────────────────────────────────────
if [[ ! -f "$CAST_DB" ]]; then
  echo "Error: cast.db not found at ${CAST_DB}" >&2
  echo "       Run: scripts/cast-db-init.sh to initialize the database" >&2
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "Error: sqlite3 not found in PATH" >&2
  exit 1
fi

# ── Detect current project from git ─────────────────────────────────────────
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
PROJECT_NAME=""
if [[ -n "$PROJECT_ROOT" ]]; then
  PROJECT_NAME=$(basename "$PROJECT_ROOT")
fi

# ── Insert task into queue ───────────────────────────────────────────────────
INSERTED_ID=$(python3 - "$CAST_DB" "$AGENT_NAME" "$TASK_TEXT" \
  "$PRIORITY" "$SCHEDULED_FOR" "$PROJECT_NAME" "$PROJECT_ROOT" <<'PYEOF'
import sys, sqlite3

db_path      = sys.argv[1]
agent        = sys.argv[2]
task         = sys.argv[3]
priority     = int(sys.argv[4])
sched_for    = sys.argv[5] if sys.argv[5] else None
project      = sys.argv[6] if sys.argv[6] else None
project_root = sys.argv[7] if sys.argv[7] else None

try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("""
        INSERT INTO task_queue
          (created_at, project, project_root, agent, task,
           priority, status, scheduled_for)
        VALUES
          (datetime('now'), ?, ?, ?, ?,
           ?, 'pending', ?)
    """, (project, project_root, agent, task, priority, sched_for))
    con.commit()
    print(cur.lastrowid)
    con.close()
except Exception as e:
    print(f"Error: DB insert failed — {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

if [[ -z "${INSERTED_ID:-}" ]]; then
  echo "Error: failed to insert task into queue" >&2
  exit 1
fi

# ── Success output ───────────────────────────────────────────────────────────
if [[ -n "$SCHEDULED_FOR" ]]; then
  echo "Queued task ${INSERTED_ID}: agent=${AGENT_NAME} priority=${PRIORITY} scheduled=${SCHEDULED_FOR}"
else
  echo "Queued task ${INSERTED_ID}: agent=${AGENT_NAME} priority=${PRIORITY} (run immediately)"
fi

exit 0
