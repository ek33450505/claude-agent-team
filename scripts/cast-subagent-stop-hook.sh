#!/bin/bash
# cast-subagent-stop-hook.sh — CAST SubagentStop hook
# Hook event: SubagentStop
#
# Fires when a subagent stops (naturally or at turn limit).
# Responsibilities:
#   1. Emit task_completed or task_blocked event to ~/.claude/cast/events/
#   2. Mirror completed/blocked status to cast.db agent_runs table if accessible
#   3. If agent output contains [TURN CEILING], write checkpoint log to
#      ~/.claude/cast/turn-ceiling-events/
#
# Stdin JSON fields (SubagentStop):
#   agent_name      — name of the subagent that stopped
#   session_id      — parent session ID
#   output          — agent's final output text (may be large)
#   stop_reason     — reason for stop (e.g. "max_turns", "end_turn", "error")
#
# Exit codes:
#   0 — always (hook must not block the parent session)
#
# Installation (add to ~/.claude/settings.json under "hooks"):
#   "SubagentStop": [
#     {
#       "hooks": [
#         {
#           "type": "command",
#           "command": "bash ~/Projects/personal/claude-agent-team/scripts/cast-subagent-stop-hook.sh"
#         }
#       ]
#     }
#   ]

# SubagentStop fires inside the parent session — CLAUDE_SUBPROCESS is NOT set here.
# No subprocess guard needed.

# Never fail loudly — a broken hook must not interrupt the parent session.
set +e

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
TURN_CEILING_DIR="${CAST_DIR}/turn-ceiling-events"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
STOP_ERROR_LOG="${HOME}/.claude/logs/subagent-stop-errors.log"
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

mkdir -p "$EVENTS_DIR" 2>/dev/null || true

# Read stdin once
INPUT="$(cat 2>/dev/null)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse fields from JSON input via env var (never interpolate into Python source)
export CAST_STOP_INPUT="$INPUT"

PARSED="$(python3 - <<'PYEOF' 2>/dev/null
import sys, json, os

raw = os.environ.get('CAST_STOP_INPUT', '')
if not raw:
    print(json.dumps({"error": "no input"}))
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print(json.dumps({"error": "invalid json"}))
    sys.exit(0)

result = {
    "agent_name": data.get("agent_name") or data.get("subagent_name") or "unknown",
    "session_id": data.get("session_id") or "",
    "stop_reason": data.get("stop_reason") or "",
    "output_preview": (data.get("output") or "")[:200],
    "has_turn_ceiling": "[TURN CEILING]" in (data.get("output") or ""),
    "output_full": data.get("output") or "",
    "agent_id": data.get("agent_id") or data.get("subagent_id") or "",
}
print(json.dumps(result))
PYEOF
)" || true

if [ -z "$PARSED" ] || echo "$PARSED" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
  : # parsed ok or we'll fall through
else
  exit 0
fi

# Extract individual fields via env var
export CAST_STOP_PARSED="$PARSED"

AGENT_NAME="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('agent_name','unknown'))" 2>/dev/null || echo "unknown")"
SESSION_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('session_id',''))" 2>/dev/null || echo "")"
STOP_REASON="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('stop_reason',''))" 2>/dev/null || echo "")"
HAS_TURN_CEILING="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print('1' if d.get('has_turn_ceiling') else '0')" 2>/dev/null || echo "0")"
AGENT_ID="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('agent_id',''))" 2>/dev/null || echo "")"
export CAST_STOP_AGENT_ID="$AGENT_ID"

# Determine event type: blocked if [TURN CEILING] or stop_reason indicates error
EVENT_TYPE="task_completed"
if [ "$HAS_TURN_CEILING" = "1" ]; then
  EVENT_TYPE="task_blocked"
elif echo "$STOP_REASON" | grep -qiE "(error|fail|rate.?limit|timeout)" 2>/dev/null; then
  EVENT_TYPE="task_blocked"
fi

# ── Step 1: Write event to ~/.claude/cast/events/ ─────────────────────────────
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))")"
TIMESTAMP_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat()+'Z')" | sed 's/+00:00//')"
SAFE_AGENT="${AGENT_NAME//[^a-zA-Z0-9_-]/}"
EVENT_FILE="${EVENTS_DIR}/${TIMESTAMP}-${SAFE_AGENT}-subagent-stop.json"

export CAST_STOP_EVENT_TYPE="$EVENT_TYPE"
export CAST_STOP_AGENT="$AGENT_NAME"
export CAST_STOP_SESSION="$SESSION_ID"
export CAST_STOP_REASON="$STOP_REASON"
export CAST_STOP_TS_ISO="$TIMESTAMP_ISO"
export CAST_STOP_EVENT_FILE="$EVENT_FILE"

python3 - <<'PYEOF' 2>/dev/null || true
import json, os

event = {
    "event_id":    os.environ.get('CAST_STOP_AGENT','unknown') + '-subagent-stop-' + os.environ.get('CAST_STOP_TS_ISO',''),
    "timestamp":   os.environ.get('CAST_STOP_TS_ISO',''),
    "event_type":  os.environ.get('CAST_STOP_EVENT_TYPE','task_completed'),
    "agent":       os.environ.get('CAST_STOP_AGENT','unknown'),
    "session_id":  os.environ.get('CAST_STOP_SESSION',''),
    "stop_reason": os.environ.get('CAST_STOP_REASON',''),
    "source":      "SubagentStop",
}

filepath = os.environ.get('CAST_STOP_EVENT_FILE','')
if filepath:
    with open(filepath, 'w') as f:
        json.dump(event, f, indent=2)
PYEOF

# ── Step 2: Mirror to cast.db agent_runs (best-effort) ───────────────────────
# The cast.db agent_runs table tracks agent invocations. If the DB exists and
# is initialized, update the most recent running row for this agent/session.
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  DB_STATUS="DONE"
  if [ "$EVENT_TYPE" = "task_blocked" ]; then
    DB_STATUS="BLOCKED"
  fi
  export CAST_STOP_DB_STATUS="$DB_STATUS"
  python3 - <<'PYEOF' 2>>"$STOP_ERROR_LOG" || true
import subprocess, os

db    = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent = os.environ.get('CAST_STOP_AGENT', '')
sess  = os.environ.get('CAST_STOP_SESSION', '')
ts    = os.environ.get('CAST_STOP_TS_ISO', '')
st    = os.environ.get('CAST_STOP_DB_STATUS', 'DONE')

if not agent or not db:
    raise SystemExit(0)

# Update the running row for this agent. Use agent_id for precise matching when
# available; fall back to MAX(id) heuristic when agent_id is absent.
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
if agent_id:
    update_sql = (
        f"UPDATE agent_runs SET status='{st}', ended_at='{ts}' "
        f"WHERE status='running' AND agent_id='{agent_id}';"
    )
else:
    update_sql = (
        f"UPDATE agent_runs SET status='{st}', ended_at='{ts}' "
        f"WHERE status='running' AND agent='{agent}' AND session_id='{sess}' "
        f"AND id=(SELECT MAX(id) FROM agent_runs WHERE status='running' AND agent='{agent}' AND session_id='{sess}');"
    )
subprocess.run(['sqlite3', db, update_sql], capture_output=True, timeout=5)
PYEOF
fi

# ── Step 3: Turn ceiling checkpoint ──────────────────────────────────────────
if [ "$HAS_TURN_CEILING" = "1" ]; then
  mkdir -p "$TURN_CEILING_DIR" 2>/dev/null || true
  CEIL_FILE="${TURN_CEILING_DIR}/${TIMESTAMP}-${SAFE_AGENT}.json"

  export CAST_CEIL_FILE="$CEIL_FILE"
  python3 - <<'PYEOF' 2>/dev/null || true
import json, os

raw = os.environ.get('CAST_STOP_PARSED', '{}')
try:
    parsed = json.loads(raw)
except Exception:
    parsed = {}

checkpoint = {
    "timestamp":    os.environ.get('CAST_STOP_TS_ISO', ''),
    "agent":        os.environ.get('CAST_STOP_AGENT', 'unknown'),
    "session_id":   os.environ.get('CAST_STOP_SESSION', ''),
    "stop_reason":  os.environ.get('CAST_STOP_REASON', ''),
    "event":        "turn_ceiling_hit",
    "output_preview": parsed.get("output_preview", ""),
    "resume_hint":  "Re-invoke the agent with --resume or dispatch orchestrator to continue from last checkpoint.",
}

filepath = os.environ.get('CAST_CEIL_FILE', '')
if filepath:
    with open(filepath, 'w') as f:
        json.dump(checkpoint, f, indent=2)
PYEOF
fi

# ── Step 4: Chain dispatch (pipeline automation) ──────────────────────────────
# When an agent completes DONE, check chain-map.json for defined successors
# and enqueue them via cast-queue-add.sh.
CHAIN_MAP="${HOME}/.claude/config/chain-map.json"
QUEUE_ADD="${HOME}/.claude/scripts/cast-queue-add.sh"

if [ "$EVENT_TYPE" = "task_completed" ] && [ -f "$CHAIN_MAP" ] && [ -f "$QUEUE_ADD" ]; then
  export CAST_CHAIN_MAP="$CHAIN_MAP"
  SUCCESSORS="$(python3 - <<'PYEOF' 2>/dev/null
import json, os
chain_map_path = os.environ.get('CAST_CHAIN_MAP', '')
agent = os.environ.get('CAST_STOP_AGENT', '')
try:
    with open(chain_map_path) as f:
        chain = json.load(f)
    successors = chain.get(agent, [])
    print('\n'.join(successors))
except Exception:
    pass
PYEOF
  )"
  if [ -n "$SUCCESSORS" ]; then
    while IFS= read -r successor; do
      [ -n "$successor" ] && bash "$QUEUE_ADD" "$successor" "$SESSION_ID" 2>/dev/null || true
    done <<< "$SUCCESSORS"
  fi
fi

# ── Step 5: Auto-resume detection for orchestrator context-limit stops ────────
# Fires when an orchestrator agent stops mid-run without completing all batches.
# Writes a resume-request JSON to ~/.claude/cast/resume-queue/ and notifies.
CKPT_LOG="${HOME}/.claude/cast/orchestrator-checkpoint.log"

if echo "$AGENT_NAME" | grep -qiE "orchestrator"; then
  if [ -f "$CKPT_LOG" ]; then
    # Check the checkpoint does NOT end with [ORCHESTRATOR DONE]
    if ! tail -1 "$CKPT_LOG" 2>/dev/null | grep -q '\[ORCHESTRATOR DONE\]'; then
      # Only trigger on clean stops, not errors
      if echo "$STOP_REASON" | grep -qiE "^(end_turn|max_turns)$"; then

        LAST_BATCH="$(grep 'BATCH.*COMPLETE' "$CKPT_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+')"
        NEXT_BATCH="$((${LAST_BATCH:-0} + 1))"
        PLAN_FILE="$(grep '^\[PLAN\]' "$CKPT_LOG" 2>/dev/null | tail -1 | sed 's/\[PLAN\] //')"

        RESUME_DIR="${HOME}/.claude/cast/resume-queue"
        mkdir -p "$RESUME_DIR" 2>/dev/null || true

        TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))")"
        OUT="${RESUME_DIR}/${TS}-orchestrator.json"

        export CAST_RESUME_TS="$TS"
        export CAST_RESUME_PLAN_FILE="${PLAN_FILE:-}"
        export CAST_RESUME_NEXT_BATCH="$NEXT_BATCH"
        export CAST_RESUME_CKPT="$CKPT_LOG"
        export CAST_RESUME_OUT="$OUT"

        python3 - <<'PYEOF' 2>/dev/null || true
import json, os

out  = os.environ.get('CAST_RESUME_OUT', '')
if not out:
    raise SystemExit(0)

payload = {
    "version":           1,
    "timestamp":         os.environ.get('CAST_RESUME_TS', ''),
    "plan_file":         os.environ.get('CAST_RESUME_PLAN_FILE') or None,
    "resume_from_batch": int(os.environ.get('CAST_RESUME_NEXT_BATCH', '1')),
    "checkpoint_log":    os.environ.get('CAST_RESUME_CKPT', ''),
}
with open(out, 'w') as f:
    json.dump(payload, f, indent=2)
PYEOF

        # Notify user
        NOTIFY_MSG="Orchestrator stopped mid-run after Batch ${LAST_BATCH:-0} — run /orchestrate to resume"
        bash "${HOME}/.claude/scripts/cast-notify.sh" "$NOTIFY_MSG" 2>/dev/null || true

        # Emit task_blocked event
        if [ -f "${HOME}/.claude/scripts/cast-events.sh" ]; then
          # shellcheck source=/dev/null
          source "${HOME}/.claude/scripts/cast-events.sh" 2>/dev/null || true
          cast_emit_event 'task_blocked' 'orchestrator' 'session' '' \
            "Orchestrator stopped at batch ${LAST_BATCH:-0} without DONE sentinel" \
            'BLOCKED' 2>/dev/null || true
        fi

      fi
    fi
  fi
fi

exit 0
