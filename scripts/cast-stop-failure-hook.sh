#!/bin/bash
# cast-stop-failure-hook.sh — CAST StopFailure hook
# Hook event: StopFailure
#
# Fires when a subagent stops due to an error (rate limit, API failure, etc.).
# Responsibilities:
#   1. Log a stop_failure event to ~/.claude/cast/events/ as
#      {timestamp}-stop-failure.json
#   2. Send a macOS desktop notification via osascript
#
# Stdin JSON fields (StopFailure):
#   agent_name  — name of the subagent that failed
#   session_id  — parent session ID
#   error       — error message or reason
#
# Exit codes:
#   0 — always (hook must not block the parent session)
#
# Installation (add to ~/.claude/settings.json under "hooks"):
#   "StopFailure": [
#     {
#       "hooks": [
#         {
#           "type": "command",
#           "command": "bash ~/Projects/personal/claude-agent-team/scripts/cast-stop-failure-hook.sh"
#         }
#       ]
#     }
#   ]

# StopFailure fires in the parent session context.
# No subprocess guard needed.

# Never fail loudly — a broken hook must not interrupt the parent session.
set +e

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"

mkdir -p "$EVENTS_DIR" 2>/dev/null || true

# Read stdin once
INPUT="$(cat 2>/dev/null)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse fields via env var — never interpolate into Python source
export CAST_FAIL_INPUT="$INPUT"

PARSED="$(python3 - <<'PYEOF' 2>/dev/null
import sys, json, os

raw = os.environ.get('CAST_FAIL_INPUT', '')
if not raw:
    print(json.dumps({"error": "no input"}))
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    # If stdin is not JSON (e.g., empty or plain text), create a minimal record
    print(json.dumps({"agent_name": "unknown", "session_id": "", "error": raw[:200]}))
    sys.exit(0)

result = {
    "agent_name": data.get("agent_name") or data.get("subagent_name") or "unknown",
    "session_id": data.get("session_id") or "",
    "error":      (data.get("error") or data.get("stop_reason") or "unknown failure")[:500],
}
print(json.dumps(result))
PYEOF
)" || true

AGENT_NAME="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_FAIL_INPUT','{}') if not os.environ.get('CAST_FAIL_PARSED') else os.environ.get('CAST_FAIL_PARSED','{}')); print(d.get('agent_name','unknown'))" 2>/dev/null || echo "unknown")"

# Use parsed output if available
if [ -n "$PARSED" ]; then
  export CAST_FAIL_PARSED="$PARSED"
  AGENT_NAME="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_FAIL_PARSED','{}')); print(d.get('agent_name','unknown'))" 2>/dev/null || echo "unknown")"
  SESSION_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_FAIL_PARSED','{}')); print(d.get('session_id',''))" 2>/dev/null || echo "")"
  ERROR_MSG="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_FAIL_PARSED','{}')); print(d.get('error','unknown failure'))" 2>/dev/null || echo "unknown failure")"
else
  SESSION_ID=""
  ERROR_MSG="unknown failure"
fi

# ── Step 1: Write stop_failure event to ~/.claude/cast/events/ ────────────────
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))")"
TIMESTAMP_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat()+'Z')" | sed 's/+00:00//')"
EVENT_FILE="${EVENTS_DIR}/${TIMESTAMP}-stop-failure.json"

export CAST_FAIL_AGENT="$AGENT_NAME"
export CAST_FAIL_SESSION="$SESSION_ID"
export CAST_FAIL_ERROR="$ERROR_MSG"
export CAST_FAIL_TS_ISO="$TIMESTAMP_ISO"
export CAST_FAIL_EVENT_FILE="$EVENT_FILE"

python3 - <<'PYEOF' 2>/dev/null || true
import json, os

event = {
    "event_id":   "stop-failure-" + os.environ.get('CAST_FAIL_TS_ISO', ''),
    "timestamp":  os.environ.get('CAST_FAIL_TS_ISO', ''),
    "event_type": "stop_failure",
    "agent":      os.environ.get('CAST_FAIL_AGENT', 'unknown'),
    "session_id": os.environ.get('CAST_FAIL_SESSION', ''),
    "error":      os.environ.get('CAST_FAIL_ERROR', 'unknown failure'),
    "source":     "StopFailure",
}

filepath = os.environ.get('CAST_FAIL_EVENT_FILE', '')
if filepath:
    with open(filepath, 'w') as f:
        json.dump(event, f, indent=2)
PYEOF

# ── Step 2: macOS desktop notification ───────────────────────────────────────
# Truncate agent name and error for display — osascript is sensitive to long strings
DISPLAY_AGENT="${AGENT_NAME:0:40}"
DISPLAY_ERROR="${ERROR_MSG:0:80}"

export CAST_NOTIFY_AGENT="$DISPLAY_AGENT"
export CAST_NOTIFY_ERROR="$DISPLAY_ERROR"

# Use env vars in a heredoc so that special characters in agent name/error
# do not break the osascript invocation
OSACODE="display notification \"CAST agent stopped with failure: ${DISPLAY_AGENT}\" with title \"CAST StopFailure\""

osascript -e "$OSACODE" 2>/dev/null || true

exit 0
