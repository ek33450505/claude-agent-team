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

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
HOOK_ERROR_LOG="${HOME}/.claude/logs/hook-errors.log"
if ! { mkdir -p "$(dirname "$HOOK_ERROR_LOG")" 2>/dev/null && touch "$HOOK_ERROR_LOG" 2>/dev/null; }; then
  HOOK_ERROR_LOG="/dev/null"
fi

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
TURN_CEILING_DIR="${CAST_DIR}/turn-ceiling-events"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

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


# Extract response text — try structured agent_response.content first (Phase C payload),
# then fall back to flat last_assistant_message / output fields (older dispatch paths).
# This multi-path approach fixes truncation underrecording: cast-truncation-check.sh
# only reads agent_response.content, so agents dispatched via older paths were missed.
response_text = ''
try:
    agent_response = data.get('agent_response') or {}
    content_blocks = agent_response.get('content') or []
    if isinstance(content_blocks, list) and content_blocks:
        texts = [
            block.get('text', '')
            for block in content_blocks
            if isinstance(block, dict) and block.get('type') == 'text'
        ]
        response_text = '\n'.join(t for t in texts if t)
except Exception:
    response_text = ''

# Flat-field fallback: last_assistant_message or output
if not response_text:
    response_text = (
        data.get('last_assistant_message') or
        data.get('output') or
        data.get('body') or
        ''
    )

flat_output = data.get("last_assistant_message") or data.get("output") or ""

result = {
    # SubagentStop stdin uses 'agent_type' (not 'agent_name') per Claude Code source.
    # 'agent_name' and 'subagent_name' are not sent by Claude Code; 'agent_type' is
    # the correct field (from createBaseHookInput + SubagentStop payload).
    "agent_name": data.get("agent_type") or data.get("agent_name") or data.get("subagent_name") or "unknown",
    "session_id": data.get("session_id") or "",
    "stop_reason": data.get("stop_reason") or "",
    "output_preview": (flat_output or response_text)[:200],
    "has_turn_ceiling": "[TURN CEILING]" in (flat_output or response_text),
    "output_full": flat_output or response_text,
    "response_text": response_text,
    "agent_id": data.get("agent_id") or data.get("subagent_id") or "",
    "duration_ms": data.get("duration_ms") or data.get("total_duration_ms") or 0,
    "tool_uses": len(data.get("tool_uses", [])) if isinstance(data.get("tool_uses"), list) else (data.get("tool_use_count") or 0),
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
DURATION_MS="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('duration_ms',0))" 2>/dev/null || echo 0)"
TOOL_USES="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('tool_uses',0))" 2>/dev/null || echo 0)"
export CAST_STOP_AGENT_ID="$AGENT_ID"
export CAST_STOP_DURATION_MS="$DURATION_MS"
export CAST_STOP_TOOL_USES="$TOOL_USES"

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
# Trust boundary: safe_agent sanitization is defensive-only.
# The agent name originates from Claude Code's trusted SubagentStop payload;
# this sanitization guards against future input-source changes, not current untrusted input.
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
# Also captures the agent's full response text for dashboard work-log feed.
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  DB_STATUS="DONE"
  if [ "$EVENT_TYPE" = "task_blocked" ]; then
    DB_STATUS="BLOCKED"
  fi
  export CAST_STOP_DB_STATUS="$DB_STATUS"
  export CAST_STOP_RESPONSE_TEXT="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('response_text','') or d.get('output_full',''))" 2>/dev/null || echo "")"
  python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import sqlite3, os

db    = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent = os.environ.get('CAST_STOP_AGENT', '')
sess  = os.environ.get('CAST_STOP_SESSION', '')
ts    = os.environ.get('CAST_STOP_TS_ISO', '')
st    = os.environ.get('CAST_STOP_DB_STATUS', 'DONE')
duration_ms   = int(os.environ.get('CAST_STOP_DURATION_MS', '0') or '0')
tool_uses     = int(os.environ.get('CAST_STOP_TOOL_USES', '0') or '0')
response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '') or None

if not agent or not db:
    raise SystemExit(0)

# Add new telemetry columns if they don't exist (idempotent — migration 011)
try:
    conn = sqlite3.connect(db, timeout=5)
    for col, coltype in [
        ('duration_ms', 'INTEGER'),
        ('tool_uses',   'INTEGER'),
        ('response',    'TEXT'),
    ]:
        try:
            conn.execute(f'ALTER TABLE agent_runs ADD COLUMN {col} {coltype}')
        except Exception:
            pass  # column already exists
    conn.commit()
    conn.close()
except Exception:
    pass

# Update the running row for this agent. Use agent_id for precise matching when
# available; fall back to MIN(id) FIFO heuristic when agent_id is absent.
# FIFO: oldest started row of this type is the one that just finished first.
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
for attempt in range(3):
    try:
        conn = sqlite3.connect(db, timeout=5)
        cur  = conn.cursor()
        if agent_id:
            cur.execute(
                "UPDATE agent_runs SET status=?, ended_at=?, duration_ms=?, tool_uses=?, response=? "
                "WHERE status='running' AND agent_id=?",
                (st, ts, duration_ms, tool_uses, response_text, agent_id),
            )
        else:
            cur.execute(
                "UPDATE agent_runs SET status=?, ended_at=?, duration_ms=?, tool_uses=?, response=? "
                "WHERE status='running' AND agent=? AND session_id=? "
                "AND id=(SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent=? AND session_id=?)",
                (st, ts, duration_ms, tool_uses, response_text, agent, sess, agent, sess),
            )
        rows_affected = conn.execute("SELECT changes()").fetchone()[0]
        conn.commit()
        conn.close()
        if rows_affected > 0 or attempt == 2:
            break
        import time as _time; _time.sleep(0.1)
    except Exception:
        try: conn.close()
        except Exception: pass
        if attempt < 2:
            import time as _time; _time.sleep(0.1)
        break
PYEOF
fi

# ── Step 2.1: Truncation logging for all agents ───────────────────────────────
# cast-truncation-check.sh only fires for a subset of agents (via worktree-check
# hook matcher: code-writer|debugger|test-writer|security|frontend-qa).
# This step fills the gap: log truncations for ALL agents directly from this hook.
# Uses response_text (already extracted above) — same payload, same detection logic.
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import sqlite3, os, re

db           = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent        = os.environ.get('CAST_STOP_AGENT', '')
sess         = os.environ.get('CAST_STOP_SESSION', '')
agent_id     = os.environ.get('CAST_STOP_AGENT_ID', '')
ts           = os.environ.get('CAST_STOP_TS_ISO', '')
response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '') or ''

# Only process non-trivial responses (mirrors cast-truncation-check.sh guard)
if len(response_text.strip()) < 50:
    raise SystemExit(0)

# Detection: prose Status block
has_status = bool(re.search(
    r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)',
    response_text,
))
# Detection: JSON fenced status block
has_json = bool(re.search(
    r'```json\s+status[\s\S]*?"status"\s*:\s*"(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)"',
    response_text, re.IGNORECASE,
))

if has_status or has_json:
    raise SystemExit(0)

# Response appears truncated — log to agent_truncations
last_line  = response_text[-200:] if len(response_text) > 200 else response_text
char_count = len(response_text)
partial_work_log = ''
wl_match = re.search(r'## Work Log\s*([\s\S]*?)(?=\Z|Status:)', response_text)
if wl_match:
    partial_work_log = wl_match.group(1).strip()[:2000]

try:
    conn = sqlite3.connect(db, timeout=5)
    # Ensure partial_work_log column exists (added in Phase 1)
    try:
        conn.execute('ALTER TABLE agent_truncations ADD COLUMN partial_work_log TEXT')
    except Exception:
        pass
    conn.execute(
        'INSERT INTO agent_truncations '
        '(session_id, agent_type, agent_id, last_line, timestamp, char_count, has_status, has_json, partial_work_log) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        (sess, agent, agent_id or None, last_line, ts, char_count, 0, 0, partial_work_log or None),
    )
    conn.commit()
    conn.close()
except Exception:
    try: conn.close()
    except Exception: pass
PYEOF
fi

# ── Step 2.5: Quality gate logging ──────────────────────────────────────────
# When a gate agent (code-reviewer, test-runner, security) finishes, extract its
# Status line and insert a row into quality_gates for dashboard observability.
#   DONE                 → pass
#   DONE_WITH_CONCERNS   → warn
#   BLOCKED              → block
#   NEEDS_CONTEXT        → warn
# Other agents are skipped.
# Export the full agent output up-front — Step 3.5 (truncation detection)
# exports it again below; this earlier export lets quality-gate logging read it.
export CAST_STOP_OUTPUT_FULL="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('output_full','') or d.get('last_assistant_message',''))" 2>/dev/null || echo "")"

if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  case "$AGENT_NAME" in
    code-reviewer|test-runner|security)
      export CAST_QG_GATE_TYPE="$(case "$AGENT_NAME" in
        code-reviewer) echo "code_review" ;;
        test-runner)   echo "test_run" ;;
        security)      echo "security_scan" ;;
      esac)"
      python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import sqlite3, os, re

db    = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent = os.environ.get('CAST_STOP_AGENT', '')
sess  = os.environ.get('CAST_STOP_SESSION', '')
out   = os.environ.get('CAST_STOP_OUTPUT_FULL', '')
gtype = os.environ.get('CAST_QG_GATE_TYPE', 'code_review')

if not agent or not db:
    raise SystemExit(0)

# Extract Status line from full output (no tail window — avoids FP for long Work Logs)
m = re.search(r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)', out)
if not m:
    raise SystemExit(0)

status = m.group(1)
result = {
    'DONE': 'pass',
    'DONE_WITH_CONCERNS': 'warn',
    'BLOCKED': 'block',
    'NEEDS_CONTEXT': 'warn',
}.get(status, 'warn')

# Grab feedback: the "Summary:" line if present, else first 500 chars of output
fm = re.search(r'Summary:\s*(.+)', out)
feedback = (fm.group(1).strip() if fm else out.strip())[:500]

try:
    conn = sqlite3.connect(db, timeout=5)
    conn.execute(
        'INSERT INTO quality_gates (session_id, agent, gate_type, gate_result, feedback) '
        'VALUES (?, ?, ?, ?, ?)',
        (sess, agent, gtype, result, feedback),
    )
    conn.commit()
    conn.close()
except Exception:
    try: conn.close()
    except Exception: pass
PYEOF
      ;;
  esac
fi

# ── Step 2.6: Claimed-work verification (observability only) ───────────────────
# Category 1 hallucination guard: verify agent's file work claims against reality.
# Extracts claimed paths from Work Log and checks if files were actually modified
# after the agent started. Logs discrepancies to agent_hallucinations table (no block).
if [[ -n "${CAST_STOP_RESPONSE_TEXT:-}" ]] && command -v python3 >/dev/null 2>&1; then
  CAST_AGENT_NAME="${AGENT_NAME}" \
  CAST_SESSION_ID="${SESSION_ID}" \
  CAST_AGENT_START_TIME="${TIMESTAMP_ISO}" \
  CAST_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")" \
  CAST_DB_PATH="${DB_PATH}" \
  python3 "$(dirname "$0")/cast_claimed_work_verifier.py" 2>/dev/null || true
fi

# ── Step 2.7: Memory write — extract ## Facts block and persist to agent_memories ──
# Agents emit ## Facts blocks (pipe-delimited fields: name, type, content, confidence)
# Parser extracts, validates, and writes to agent_memories table with deduplication.
if [[ -n "${CAST_STOP_RESPONSE_TEXT:-}" ]] && command -v python3 >/dev/null 2>&1; then
  CAST_STOP_AGENT="${AGENT_NAME}" \
  CAST_STOP_RESPONSE_TEXT="${CAST_STOP_RESPONSE_TEXT}" \
  CAST_DB_PATH="${DB_PATH}" \
  CAST_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")" \
  python3 - 2>>"$HOOK_ERROR_LOG" <<'PYEOF' || true
import os, sys, re, sqlite3
from datetime import datetime, timezone

agent = os.environ.get('CAST_STOP_AGENT', 'unknown')
response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')
db_path = os.environ.get('CAST_DB_PATH', '').strip()
project_root = os.environ.get('CAST_PROJECT_ROOT', '').strip()

if not response_text or not db_path:
    sys.exit(0)

# Extract ## Facts block (scan from start, stop at next ## heading or end)
facts_match = re.search(r'## Facts\s*\n(.*?)(?=\n##|\Z)', response_text, re.DOTALL)
if not facts_match:
    sys.exit(0)

facts_block = facts_match.group(1).strip()
MAX_FACTS = 5
parsed = 0

try:
    db_path = os.path.expanduser(db_path)
    conn = sqlite3.connect(db_path, timeout=5)

    # Ensure optional columns exist (idempotent)
    try:
        conn.execute('ALTER TABLE agent_memories ADD COLUMN confidence REAL DEFAULT 1.0')
    except Exception:
        pass  # column already exists or table doesn't exist yet
    try:
        conn.execute('ALTER TABLE agent_memories ADD COLUMN valid_from TEXT')
    except Exception:
        pass
    try:
        conn.execute('ALTER TABLE agent_memories ADD COLUMN valid_to TEXT')
    except Exception:
        pass

    now = datetime.now(timezone.utc).isoformat()

    for line in facts_block.splitlines():
        if parsed >= MAX_FACTS:
            break
        line = line.strip()
        if not line:
            continue

        # Parse pipe-delimited fields: name: X | type: Y | content: Z | confidence: W
        fields = {}
        for part in line.split('|'):
            if ':' in part:
                k, _, v = part.strip().partition(':')
                fields[k.strip()] = v.strip()

        name = fields.get('name', '')
        mem_type = fields.get('type', '')
        content = fields.get('content', '')[:500]
        confidence_str = fields.get('confidence', '1.0')
        try:
            confidence = float(confidence_str) if confidence_str else 1.0
        except ValueError:
            confidence = 1.0

        VALID_TYPES = {'user', 'feedback', 'project', 'reference', 'procedural', 'user_profile'}
        SLUG_RE = re.compile(r'^[a-zA-Z0-9_-]{1,80}$')

        # Validate all fields
        if not name or not SLUG_RE.match(name) or mem_type not in VALID_TYPES or not content:
            continue

        # Deduplication: match on (agent, name) — update if exists, otherwise insert
        cur = conn.cursor()
        cur.execute(
            "SELECT id FROM agent_memories WHERE agent = ? AND name = ? LIMIT 1",
            (agent, name)
        )
        existing = cur.fetchone()

        if existing:
            # Update: overwrite content, reset valid_to, bump updated_at
            cur.execute(
                "UPDATE agent_memories SET content=?, updated_at=?, confidence=?, valid_to=NULL "
                "WHERE id=?",
                (content, now, confidence, existing[0])
            )
        else:
            # Insert new memory entry
            project = os.path.basename(project_root.rstrip('/')) if project_root else 'unknown'
            cur.execute(
                "INSERT INTO agent_memories "
                "(agent, project, type, name, description, content, created_at, updated_at, confidence, valid_from) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (agent, project, mem_type, name, content[:100], content, now, now, confidence, now)
            )

        parsed += 1

    conn.commit()
    conn.close()

    if parsed > 0:
        print(f"[CAST-MEMORY] Wrote {parsed} facts from {agent}", file=sys.stderr)

except Exception as e:
    try:
        log_path = os.path.expanduser('~/.claude/logs/hook-errors.log')
        with open(log_path, 'a') as f:
            f.write(f"[memory-write] {e}\n")
    except Exception:
        pass
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

# ── Step 3.5: Truncation detection ───────────────────────────────────────────
# A well-formed agent output ends with a Status: <VALUE> line.
# If missing, the agent was truncated mid-execution.
export CAST_STOP_OUTPUT_FULL="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_STOP_PARSED','{}')); print(d.get('output_full','') or d.get('last_assistant_message',''))" 2>/dev/null || echo "")"

TRUNCATED="$(python3 - <<'PYEOF' 2>/dev/null
import re, os
output = os.environ.get('CAST_STOP_OUTPUT_FULL', '')
# Search full output — no tail window (avoids FP for long Work Logs)
# Also accept markdown emphasis around Status verb and JSON status form
has_status = bool(re.search(r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)', output))
has_json_status = bool(re.search(r'"status"\s*:\s*"(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)"', output))
print('0' if (has_status or has_json_status) else '1')
PYEOF
)"

if [[ "${TRUNCATED:-0}" = "1" ]] \
   && [[ -n "$CAST_STOP_OUTPUT_FULL" ]] \
   && [[ -n "${CAST_STOP_AGENT:-}" ]] \
   && [[ "${CAST_STOP_AGENT:-}" != "unknown" ]]; then
  TRUNC_DIR="${HOME}/.claude/cast/truncated-agents"
  mkdir -p "$TRUNC_DIR" 2>/dev/null || true

  export CAST_TRUNC_DIR="$TRUNC_DIR"
  export CAST_TRUNC_SAFE_AGENT="$SAFE_AGENT"

  python3 - <<'PYEOF' 2>/dev/null || true
import json, os
trunc_dir = os.environ.get('CAST_TRUNC_DIR', '')
agent_raw = os.environ.get('CAST_STOP_AGENT', 'unknown')
safe_agent = os.environ.get('CAST_TRUNC_SAFE_AGENT', 'unknown') or 'unknown'
ts    = os.environ.get('CAST_STOP_TS_ISO', '')
sess  = os.environ.get('CAST_STOP_SESSION', '')
out   = os.environ.get('CAST_STOP_OUTPUT_FULL', '')
if not trunc_dir:
    raise SystemExit(0)
record = {
    "timestamp": ts, "agent": agent_raw, "session_id": sess,
    "truncation_detected": True,
    "output_tail": out[-500:] if out else "",
}
ts_safe = ts.replace(':','').replace('-','').replace('.','')
filepath = f"{trunc_dir}/{ts_safe}-{safe_agent or 'unknown'}.json"
with open(filepath, 'w') as f:
    json.dump(record, f, indent=2)
PYEOF

  # Emit directive to parent session — use SAFE_AGENT (not AGENT_NAME) to prevent JSON-breaking
  # characters from hostile hook payloads (security hardening).
  echo '{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":"[CAST-TRUNCATED] Agent '"$SAFE_AGENT"' stopped without a valid Status block. Output may be incomplete. Re-dispatch the agent or review ~/.claude/cast/truncated-agents/ for the partial output. Do NOT auto-retry expensive agents — surface this as BLOCKED."}}'
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

# ── Step 5: Auto-resume detection (DISABLED — orchestrator agent retired 2026-04-16) ─
# The orchestrator agent was retired in Task 2.1. Plan execution now runs via the
# /orchestrate skill in the main session. This block will never fire because no
# subagent named "orchestrator" is dispatched anymore. Kept for reference only.
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
