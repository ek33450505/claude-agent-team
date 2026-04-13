#!/bin/bash
# cast-teammate-idle-hook.sh — CAST TeammateIdle hook
# Hook event: TeammateIdle (Agent Teams)
#
# Fires when a teammate in an Agent Team finishes its current work and becomes
# idle. Validates the result quality, logs idle events, and emits a CAST event
# for observability.
#
# Stdin JSON fields (TeammateIdle):
#   result          — the teammate's output/result text
#   teammate_id     — ID of the idle teammate (optional)
#   teammate_name   — name/role of the teammate (optional)
#   session_id      — parent team session ID (optional)
#   completed_task  — description of the task just completed (optional)
#
# Exit codes:
#   0 — result is valid (non-empty, no placeholders)
#   2 — result is empty, missing, or contains placeholder text (blocks)

# Subprocess guard — skip if running inside a subagent
[[ "${CLAUDE_SUBPROCESS:-}" == "1" ]] && exit 0

set -euo pipefail

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
LOG_FILE="${HOME}/.claude/logs/teammate-idle.log"

mkdir -p "$EVENTS_DIR" "${HOME}/.claude/logs" 2>/dev/null || true

# Read stdin once
INPUT="$(cat 2>/dev/null || true)"
if [[ -z "$INPUT" ]]; then
  echo '{"hookSpecificOutput":{"message":"TeammateIdle: no input provided — no output from teammate"}}'
  exit 2
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")"
TIMESTAMP_FILE="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "unknown")"

# Parse JSON fields via env var (never interpolate into Python source)
export CAST_IDLE_INPUT="$INPUT"

PARSED="$(python3 - <<'PYEOF' 2>/dev/null || echo '{}'
import json, os

raw = os.environ.get('CAST_IDLE_INPUT', '')
if not raw:
    print('{}')
    raise SystemExit(0)

try:
    data = json.loads(raw)
except Exception:
    print('{}')
    raise SystemExit(0)

result = {
    "result":         data.get("result", ""),
    "teammate_id":    data.get("teammate_id", ""),
    "teammate_name":  data.get("teammate_name", data.get("agent_type", "unknown")),
    "session_id":     data.get("session_id", ""),
    "completed_task": data.get("completed_task", ""),
}
print(json.dumps(result))
PYEOF
)"

export CAST_IDLE_PARSED="$PARSED"

RESULT="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_IDLE_PARSED','{}')); print(d.get('result',''))" 2>/dev/null || echo "")"
TEAMMATE_NAME="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_IDLE_PARSED','{}')); print(d.get('teammate_name','unknown'))" 2>/dev/null || echo "unknown")"
TEAMMATE_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_IDLE_PARSED','{}')); print(d.get('teammate_id',''))" 2>/dev/null || echo "")"
SESSION_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_IDLE_PARSED','{}')); print(d.get('session_id',''))" 2>/dev/null || echo "")"

# ── Quality gate: validate result ─────────────────────────────────────────────

# Empty or missing result → block
if [[ -z "$RESULT" ]]; then
  echo '{"hookSpecificOutput":{"message":"TeammateIdle: no output from teammate — result is empty or missing"}}'
  exit 2
fi

# Placeholder detection → block
RESULT_UPPER="$(echo "$RESULT" | tr '[:lower:]' '[:upper:]')"
if echo "$RESULT_UPPER" | grep -qE '\bTODO\b|\bPLACEHOLDER\b'; then
  echo '{"hookSpecificOutput":{"message":"TeammateIdle: result contains placeholder text — TODO or PLACEHOLDER detected"}}'
  exit 2
fi

# ── Step 1: Write event to ~/.claude/cast/events/ ────────────────────────────
SAFE_NAME="${TEAMMATE_NAME//[^a-zA-Z0-9_-]/}"
EVENT_FILE="${EVENTS_DIR}/${TIMESTAMP_FILE}-${SAFE_NAME}-teammate-idle.json"

export CAST_IDLE_EVENT_FILE="$EVENT_FILE"
export CAST_IDLE_TEAMMATE="$TEAMMATE_NAME"
export CAST_IDLE_TID="$TEAMMATE_ID"
export CAST_IDLE_SESSION="$SESSION_ID"
export CAST_IDLE_TS="$TIMESTAMP"

python3 - <<'PYEOF' 2>/dev/null || true
import json, os

event = {
    "event_id":      os.environ.get('CAST_IDLE_TEAMMATE','unknown') + '-idle-' + os.environ.get('CAST_IDLE_TS',''),
    "timestamp":     os.environ.get('CAST_IDLE_TS',''),
    "event_type":    "teammate_idle",
    "teammate_name": os.environ.get('CAST_IDLE_TEAMMATE','unknown'),
    "teammate_id":   os.environ.get('CAST_IDLE_TID',''),
    "session_id":    os.environ.get('CAST_IDLE_SESSION',''),
    "source":        "TeammateIdle",
}

filepath = os.environ.get('CAST_IDLE_EVENT_FILE','')
if filepath:
    with open(filepath, 'w') as f:
        json.dump(event, f, indent=2)
PYEOF

# ── Step 2: Append to log ────────────────────────────────────────────────────
echo "${TIMESTAMP} teammate_idle ${TEAMMATE_NAME} (${TEAMMATE_ID})" >> "$LOG_FILE" 2>/dev/null || true

# ── Step 3: Emit event via cast-events.sh if available ───────────────────────
if [[ -f "${HOME}/.claude/scripts/cast-events.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.claude/scripts/cast-events.sh" 2>/dev/null || true
  cast_emit_event 'teammate_idle' "$TEAMMATE_NAME" 'team' '' \
    "Teammate ${TEAMMATE_NAME} is idle and available for work" \
    'IDLE' 2>/dev/null || true
fi

exit 0
