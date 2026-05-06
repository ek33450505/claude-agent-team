#!/usr/bin/env bash
# notify-on-agent-stop.sh — SubagentStop hook: logs agent name to a file
#
# Hook event: SubagentStop
# Fires when a dispatched subagent finishes (naturally or at turn limit).
# Appends a structured log line to ~/.claude/cast/agent-stops.log so you
# can see which agents ran and when.
#
# To also send a macOS desktop notification, uncomment the osascript line.
#
# Stdin JSON fields used:
#   agent_type  — name of the agent that stopped (Claude Code uses "agent_type")
#   session_id  — parent session ID
#   stop_reason — "end_turn", "max_turns", or "error"
#
# Exit codes:
#   0 — always (SubagentStop hooks must not block the parent session)

# SubagentStop fires in the parent session — CLAUDE_SUBPROCESS is NOT set here.
# No subprocess guard needed for this event. However, if you call any tool from
# inside this hook (e.g., dispatch another agent), those tool calls will run in
# a subprocess context and the guard would fire there.

# Never fail loudly — a broken hook must not interrupt the parent session
set +e

# Error logger
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}

# Output directory for agent stop logs
AGENT_STOP_LOG="${HOME}/.claude/cast/agent-stops.log"
mkdir -p "$(dirname "$AGENT_STOP_LOG")" 2>/dev/null || true

# Read stdin once
INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse fields via environment variable — prevents shell injection
export CAST_STOP_INPUT="$INPUT"

python3 - <<'PYEOF' 2>/dev/null || true
import json, os, sys
from datetime import datetime, timezone

raw = os.environ.get('CAST_STOP_INPUT', '')
if not raw:
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

# Claude Code sends 'agent_type', not 'agent_name' — both checked for compatibility
agent_name  = data.get('agent_type') or data.get('agent_name') or 'unknown'
session_id  = data.get('session_id', '')
stop_reason = data.get('stop_reason', '')

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

log_line = json.dumps({
    'ts':          now,
    'agent':       agent_name,
    'session_id':  session_id,
    'stop_reason': stop_reason,
})

log_path = os.path.join(os.path.expanduser('~/.claude/cast'), 'agent-stops.log')
os.makedirs(os.path.dirname(log_path), exist_ok=True)
with open(log_path, 'a') as f:
    f.write(log_line + '\n')

PYEOF

# Optional: macOS desktop notification
# Uncomment to get a Notification Center alert when any agent finishes.
# AGENT_NAME="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_INPUT','{}')); print(d.get('agent_type') or d.get('agent_name') or 'agent')" 2>/dev/null || echo 'agent')"
# osascript -e "display notification \"$AGENT_NAME finished\" with title \"CAST\"" 2>/dev/null || true

exit 0
