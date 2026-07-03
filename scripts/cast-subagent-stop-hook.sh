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
# Export HOOK_DIR and CAST_HOOK_DIR so Python heredocs can locate sibling scripts
# (cast-redact.py, cast_db.py/log_hook_failure, etc.).
export HOOK_DIR
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
export CAST_HOOK_DIR="${CAST_HOOK_DIR:-$HOOK_DIR}"

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

agent_name_raw = data.get("agent_type") or data.get("agent_name") or data.get("subagent_name") or "unknown"
agent_id_raw = data.get("agent_id") or data.get("subagent_id") or ""

# Fallback: if agent_name is "unknown" but agent_id is non-empty, query agent_runs
if agent_name_raw == "unknown" and agent_id_raw:
    try:
        import sqlite3
        db_path = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
        if os.path.isfile(db_path):
            conn = sqlite3.connect(db_path, timeout=2)
            cur = conn.cursor()
            cur.execute("SELECT agent FROM agent_runs WHERE agent_id = ? LIMIT 1", (agent_id_raw,))
            row = cur.fetchone()
            if row and row[0]:
                agent_name_raw = row[0]
            conn.close()
    except Exception:
        pass  # Fall back to "unknown" on any DB error

result = {
    # SubagentStop stdin uses 'agent_type' (not 'agent_name') per Claude Code source.
    # 'agent_name' and 'subagent_name' are not sent by Claude Code; 'agent_type' is
    # the correct field (from createBaseHookInput + SubagentStop payload).
    "agent_name": agent_name_raw,
    "session_id": data.get("session_id") or "",
    "stop_reason": data.get("stop_reason") or "",
    "output_preview": (flat_output or response_text)[:200],
    "has_turn_ceiling": "[TURN CEILING]" in (flat_output or response_text),
    "output_full": flat_output or response_text,
    "response_text": response_text,
    "agent_id": data.get("agent_id") or data.get("subagent_id") or "",
    "duration_ms": data.get("duration_ms") or data.get("total_duration_ms") or 0,
    "tool_uses": len(data.get("tool_uses", [])) if isinstance(data.get("tool_uses"), list) else (data.get("tool_use_count") or 0),
    "cache_read_input_tokens": data.get("cache_read_input_tokens"),
    "cache_creation_input_tokens": data.get("cache_creation_input_tokens"),
}
print(json.dumps(result))
PYEOF
)" || true

# Guard: exit if PARSED is empty or signals a parse error.
if [ -z "$PARSED" ]; then
  exit 0
fi

# Export PARSED so the single-extraction python3 can read it.
export CAST_STOP_PARSED="$PARSED"

# ── Single-python field extraction (collapses 9+ spawns into one) ─────────────
# Emits eval-able KEY='shlex-quoted-value' lines for every field needed downstream.
# Failure leaves all vars at safe defaults (|| assignments below); hook never aborts.
_FIELDS_RAW="$(python3 - <<'PYEOF' 2>/dev/null
import json, os, sys
try:
    import shlex
except ImportError:
    # shlex is stdlib; this branch is unreachable in practice
    sys.exit(1)

raw = os.environ.get('CAST_STOP_PARSED', '')
try:
    d = json.loads(raw)
except Exception:
    # Emit error sentinel so the shell guard below can exit early
    print("CAST_FIELDS_ERROR=1")
    sys.exit(0)

if 'error' in d:
    print("CAST_FIELDS_ERROR=1")
    sys.exit(0)

output_full   = d.get('output_full', '') or d.get('last_assistant_message', '') or ''
response_text = d.get('response_text', '') or output_full

fields = {
    'AGENT_NAME':         d.get('agent_name', 'unknown') or 'unknown',
    'SESSION_ID':         d.get('session_id', '') or '',
    'STOP_REASON':        d.get('stop_reason', '') or '',
    'HAS_TURN_CEILING':   '1' if d.get('has_turn_ceiling') else '0',
    'AGENT_ID':           d.get('agent_id', '') or '',
    'DURATION_MS':        str(d.get('duration_ms', 0) or 0),
    'TOOL_USES':          str(d.get('tool_uses', 0) or 0),
    'CACHE_READ_TOKENS':  str(d.get('cache_read_input_tokens') or ''),
    'CACHE_CREATE_TOKENS': str(d.get('cache_creation_input_tokens') or ''),
    'OUTPUT_FULL':        output_full,
    'RESPONSE_TEXT':      response_text,
    'CAST_FIELDS_ERROR':  '0',
}

for key, val in fields.items():
    # shlex.quote is MANDATORY here — the eval below is safe ONLY because every
    # emitted field is quoted. Removing shlex.quote would open a shell-injection
    # path: arbitrary agent output flows into an evaluated string downstream.
    # NOTE keep this comment free of apostrophes, backticks and dollar-paren:
    # it sits inside a command-substitution-nested heredoc that bash 3.2
    # mis-parses on the macOS CI runner.
    print(key + '=' + shlex.quote(str(val)))
PYEOF
)" || true

# Apply extracted fields; safe defaults apply if extraction failed or was empty.
# Safety contract: shlex.quote() is applied to every field in the Python block
# above — do NOT eval _FIELDS_RAW from any source that skips that quoting step.
eval "${_FIELDS_RAW:-CAST_FIELDS_ERROR=1}" 2>/dev/null || true

if [ "${CAST_FIELDS_ERROR:-1}" = "1" ]; then
  exit 0
fi

# Apply defaults for any field that eval may have left unset
AGENT_NAME="${AGENT_NAME:-unknown}"
SESSION_ID="${SESSION_ID:-}"
STOP_REASON="${STOP_REASON:-}"
HAS_TURN_CEILING="${HAS_TURN_CEILING:-0}"
AGENT_ID="${AGENT_ID:-}"
DURATION_MS="${DURATION_MS:-0}"
TOOL_USES="${TOOL_USES:-0}"
CACHE_READ_TOKENS="${CACHE_READ_TOKENS:-}"
CACHE_CREATE_TOKENS="${CACHE_CREATE_TOKENS:-}"
OUTPUT_FULL="${OUTPUT_FULL:-}"
RESPONSE_TEXT="${RESPONSE_TEXT:-}"

# Shared Status-contract helper (single source of truth; inline fallback if absent)
if [ -r "${HOME}/.claude/scripts/cast-status-contract.sh" ]; then
  # shellcheck source=/dev/null
  . "${HOME}/.claude/scripts/cast-status-contract.sh"
fi
if ! command -v cast_status_exempt_agent >/dev/null 2>&1; then
  cast_status_exempt_agent() { case "${1:-}" in general-purpose|Explore|Plan|claude|statusline-setup|output-style-setup|unknown|"") return 0;; *workflow-subagent*) return 0;; *) return 1;; esac; }
  cast_output_lacks_prose() { [ -z "$(printf '%s' "${1:-}" | tr -d '[:space:]')" ]; }
fi

# Detect agents that are exempt from the Status block contract.
# These agents either emit StructuredOutput tool results instead of prose Status blocks,
# or are Claude Code built-ins / unidentifiable agents that don't follow the CAST agent protocol.
STATUS_CONTRACT_EXEMPT="0"
if cast_status_exempt_agent "$AGENT_NAME"; then
  STATUS_CONTRACT_EXEMPT="1"
fi
export CAST_STOP_AGENT_ID="$AGENT_ID"
export CAST_STOP_DURATION_MS="$DURATION_MS"
export CAST_STOP_TOOL_USES="$TOOL_USES"
export CAST_STOP_CACHE_READ_TOKENS="$CACHE_READ_TOKENS"
export CAST_STOP_CACHE_CREATE_TOKENS="$CACHE_CREATE_TOKENS"

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

# ── #8/#10 Precondition guard: refuse to write telemetry for main-session Stop ──
# Defensive — SubagentStop should always set CAST_STOP_AGENT_ID or CAST_STOP_AGENT;
# if both are missing, refuse to write telemetry rather than capture main-session content.
[[ -n "${CAST_STOP_AGENT_ID:-}" || -n "${CAST_STOP_AGENT:-}" ]] || exit 0

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
  CAST_STOP_RESPONSE_TEXT="${RESPONSE_TEXT}"
  export CAST_STOP_RESPONSE_TEXT
  # Resolve agent transcript path for cost computation.
  # Prefer agent_transcript_path from payload; else glob by session_id + agent_id.
  CAST_STOP_TRANSCRIPT_PATH=""
  if [ -n "$AGENT_ID" ] && [ -n "$SESSION_ID" ]; then
    # Try recursive glob: covers flat AND workflow-nested paths
    # Flat:   ~/.claude/projects/*/<session_id>/subagents/agent-<agent_id>.jsonl
    # Nested: ~/.claude/projects/*/<session_id>/subagents/workflows/wf_*/agent-<agent_id>.jsonl
    CAST_STOP_TRANSCRIPT_PATH="$(python3 -c "
import glob, os, sys
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
session_id = os.environ.get('CAST_STOP_SESSION', '')
if not agent_id or not session_id:
    sys.exit(0)
pattern = os.path.expanduser(f'~/.claude/projects/*/{session_id}/subagents/**/agent-{agent_id}.jsonl')
matches = glob.glob(pattern, recursive=True)
if matches:
    print(max(matches, key=os.path.getmtime))
" 2>/dev/null || echo "")"
  fi
  export CAST_STOP_TRANSCRIPT_PATH
  export CAST_PRICING_PATH="${HOME}/.claude/config/model-pricing.json"
  # Capture the git branch of the agent's working tree for per-feature cost attribution (F1).
  CAST_STOP_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  export CAST_STOP_BRANCH
  python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import sqlite3, os, sys, json, glob
sys.path.insert(0, os.environ.get('CAST_HOOK_DIR', os.path.expanduser('~/.claude/scripts')))
try:
    from cast_db import log_hook_failure
except Exception:
    log_hook_failure = None

db    = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent = os.environ.get('CAST_STOP_AGENT', '')
sess  = os.environ.get('CAST_STOP_SESSION', '')
ts    = os.environ.get('CAST_STOP_TS_ISO', '')
st    = os.environ.get('CAST_STOP_DB_STATUS', 'DONE')
tool_uses     = int(os.environ.get('CAST_STOP_TOOL_USES', '0') or '0')
response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '') or None
cache_read    = os.environ.get('CAST_STOP_CACHE_READ_TOKENS', '') or None
cache_create  = os.environ.get('CAST_STOP_CACHE_CREATE_TOKENS', '') or None
if cache_read:
    cache_read = int(cache_read)
if cache_create:
    cache_create = int(cache_create)
branch = os.environ.get('CAST_STOP_BRANCH', '') or None

if not agent or not db:
    raise SystemExit(0)

# ── Cost computation from transcript ────────────────────────────────────────
# Defensive: all errors yield NULL cost; hook never aborts.
cost_usd = None
input_tokens = None
output_tokens = None
transcript_model = None

try:
    transcript_path = os.environ.get('CAST_STOP_TRANSCRIPT_PATH', '').strip()
    if transcript_path and os.path.isfile(transcript_path):
        total_input = 0
        total_output = 0
        total_cache_read = 0
        total_cache_create = 0
        found_usage = False

        with open(transcript_path, 'r', errors='replace') as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    obj = json.loads(raw_line)
                except Exception:
                    continue
                msg = obj.get('message', {}) if isinstance(obj.get('message'), dict) else {}
                usage = msg.get('usage') if isinstance(msg.get('usage'), dict) else obj.get('usage')
                if not isinstance(usage, dict):
                    continue
                total_input += usage.get('input_tokens', 0) or 0
                total_output += usage.get('output_tokens', 0) or 0
                total_cache_read += usage.get('cache_read_input_tokens', 0) or 0
                total_cache_create += usage.get('cache_creation_input_tokens', 0) or 0
                found_usage = True
                if not transcript_model and isinstance(msg.get('model'), str):
                    transcript_model = msg['model']

        if found_usage:
            input_tokens = total_input
            output_tokens = total_output
            # Transcript is authoritative for ALL token types — overrides payload values.
            # The SubagentStop payload's cache fields reflect only the last message, not
            # the full subagent session. For multi-message agents cache tokens dominate cost
            # and the payload would understate them by a large factor.
            cache_read = total_cache_read
            cache_create = total_cache_create

            # Load pricing table
            pricing_path = os.environ.get('CAST_PRICING_PATH', '')
            pricing_path = os.path.expanduser(pricing_path) if pricing_path else ''
            rate_in = 3.0
            rate_out = 15.0
            try:
                if pricing_path and os.path.isfile(pricing_path):
                    with open(pricing_path, 'r') as pf:
                        pricing = json.load(pf)
                    models = pricing.get('models', {})
                    model_key = transcript_model or ''
                    entry = models.get(model_key) or models.get('_default') or {}
                    rate_in = entry.get('cost_per_million_input', 3.0)
                    rate_out = entry.get('cost_per_million_output', 15.0)
            except Exception as _pe:
                if log_hook_failure:
                    log_hook_failure('cast-subagent-stop-hook:pricing_load', -1, str(_pe), sess)

            # Anthropic full cost formula (cache tokens dominate)
            cr = cache_read or 0
            cc = cache_create or 0
            cost_usd = round(
                (total_input * rate_in + total_output * rate_out + cc * rate_in * 1.25 + cr * rate_in * 0.1)
                / 1_000_000,
                6
            )
        else:
            if log_hook_failure:
                log_hook_failure('cast-subagent-stop-hook:cost_no_usage', 0,
                                 f'no usage blocks found in transcript {transcript_path}', sess)
    else:
        if transcript_path:
            # path was resolved but file doesn't exist — log it
            if log_hook_failure:
                log_hook_failure('cast-subagent-stop-hook:cost_no_transcript', 0,
                                 f'transcript not found: {transcript_path}', sess)
        # No transcript path at all — silent NULL (common for agents dispatched without agent_id)
except Exception as _ce:
    cost_usd = None
    if log_hook_failure:
        log_hook_failure('cast-subagent-stop-hook:cost_exception', -1, str(_ce), sess)

# Add new telemetry columns if they don't exist (idempotent — migration 011)
try:
    conn = sqlite3.connect(db, timeout=5)
    for col, coltype in [
        ('duration_ms', 'INTEGER'),
        ('tool_uses',   'INTEGER'),
        ('response',    'TEXT'),
        ('branch',      'TEXT'),
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
# cost_usd, input_tokens, output_tokens, model are written atomically in the same UPDATE.
agent_id = os.environ.get('CAST_STOP_AGENT_ID', '')
for attempt in range(3):
    try:
        conn = sqlite3.connect(db, timeout=5)
        cur  = conn.cursor()
        if agent_id:
            cur.execute(
                "UPDATE agent_runs SET status=?, ended_at=?, "
                "duration_ms=CAST((julianday(replace(replace(?,'T',' '),'Z','')) - julianday(replace(replace(started_at,'T',' '),'Z',''))) * 86400000 AS INTEGER), "
                "tool_uses=?, response=?, "
                "cache_read_input_tokens=?, cache_creation_input_tokens=?, "
                "cost_usd=?, input_tokens=?, output_tokens=?, model=?, branch=? "
                "WHERE id=("
                "  SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent_id=?"
                ")",
                (st, ts, ts, tool_uses, response_text, cache_read, cache_create,
                 cost_usd, input_tokens, output_tokens, transcript_model, branch, agent_id),
            )
        else:
            cur.execute(
                "UPDATE agent_runs SET status=?, ended_at=?, "
                "duration_ms=CAST((julianday(replace(replace(?,'T',' '),'Z','')) - julianday(replace(replace(started_at,'T',' '),'Z',''))) * 86400000 AS INTEGER), "
                "tool_uses=?, response=?, "
                "cache_read_input_tokens=?, cache_creation_input_tokens=?, "
                "cost_usd=?, input_tokens=?, output_tokens=?, model=?, branch=? "
                "WHERE id=("
                "  SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent=? AND session_id=?"
                ")",
                (st, ts, ts, tool_uses, response_text, cache_read, cache_create,
                 cost_usd, input_tokens, output_tokens, transcript_model, branch, agent, sess),
            )
        rows_affected = conn.execute("SELECT changes()").fetchone()[0]
        conn.commit()
        conn.close()
        if rows_affected > 0 or attempt == 2:
            break
        import time as _time; _time.sleep(0.1)
    except Exception as e:
        try: conn.close()
        except Exception: pass
        if attempt < 2:
            import time as _time; _time.sleep(0.1)
        else:
            if log_hook_failure:
                log_hook_failure('cast-subagent-stop-hook:agent_runs', -1, str(e), sess if 'sess' in dir() else None)
        break
PYEOF
fi

# ── Step 2b: dispatch_decisions outcome update (F2 record→decision loop) ─────
# Resolve the PreToolUse(Task)-captured pending decision row for this agent+session
# to its terminal outcome. FIFO MIN(id) match mirrors the agent_runs match heuristic
# (dispatch_decisions has no agent_id linkage — captured at PreToolUse before agent_id
# exists — so session_id+chosen_agent FIFO is the available key; parallel same-type
# dispatches in one session may resolve out of order — acceptable for v1).
# Best-effort, fail-soft: never blocks/crashes the hook. No pending row → no-op.
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  if [ "$EVENT_TYPE" = "task_blocked" ]; then
    CAST_STOP_DD_OUTCOME="BLOCKED"
  else
    CAST_STOP_DD_OUTCOME="DONE"
  fi
  export CAST_STOP_DD_OUTCOME
  export CAST_DB_PATH="$DB_PATH"
  python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import sqlite3, os, sys
sys.path.insert(0, os.environ.get('CAST_HOOK_DIR', os.path.expanduser('~/.claude/scripts')))
try:
    from cast_db import log_hook_failure
except Exception:
    log_hook_failure = None
db      = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent   = os.environ.get('CAST_STOP_AGENT', '')
sess    = os.environ.get('CAST_STOP_SESSION', '')
outcome = os.environ.get('CAST_STOP_DD_OUTCOME', 'DONE')
if not agent or not sess:
    raise SystemExit(0)
conn = None
try:
    conn = sqlite3.connect(db, timeout=2)
    conn.execute(
        "UPDATE dispatch_decisions SET outcome=? "
        "WHERE id=(SELECT MIN(id) FROM dispatch_decisions "
        "          WHERE outcome='pending' AND chosen_agent=? AND session_id=?)",
        (outcome, agent, sess),
    )
    conn.commit()
    conn.close()
except Exception as e:
    try:
        if conn: conn.close()
    except Exception:
        pass
    if log_hook_failure:
        log_hook_failure('cast-subagent-stop-hook:dispatch_decisions', -1, str(e), sess)
PYEOF
fi

# ── Step 2.1: Truncation logging for all agents ───────────────────────────────
# cast-truncation-check.sh only fires for a subset of agents (via worktree-check
# hook matcher: code-writer|debugger|test-writer|security|frontend-qa).
# This step fills the gap: log truncations for ALL agents directly from this hook.
# Uses response_text (already extracted above) — same payload, same detection logic.
# SKIP: agents exempt from the Status block contract (Claude Code built-ins, workflow-subagents)
# — they legitimately use StructuredOutput or other non-CAST completion patterns.
if [[ "$STATUS_CONTRACT_EXEMPT" = "0" ]] && command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import sqlite3, os, re, sys
sys.path.insert(0, os.environ.get('CAST_HOOK_DIR', os.path.expanduser('~/.claude/scripts')))
try:
    from cast_db import log_hook_failure
except Exception:
    log_hook_failure = None

db           = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent        = os.environ.get('CAST_STOP_AGENT', '')
sess         = os.environ.get('CAST_STOP_SESSION', '')
agent_id     = os.environ.get('CAST_STOP_AGENT_ID', '')
ts           = os.environ.get('CAST_STOP_TS_ISO', '')
response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '') or ''

# Fallback: if agent is "unknown" but agent_id is non-empty, query agent_runs
if agent == 'unknown' and agent_id:
    try:
        conn = sqlite3.connect(db, timeout=2)
        cur = conn.cursor()
        cur.execute("SELECT agent FROM agent_runs WHERE agent_id = ? LIMIT 1", (agent_id,))
        row = cur.fetchone()
        if row and row[0]:
            agent = row[0]
        conn.close()
    except Exception:
        pass  # Fall back to "unknown" on any DB error

# Only process non-trivial responses (mirrors cast-truncation-check.sh guard)
if len(response_text.strip()) < 50:
    raise SystemExit(0)

# agent_id lookup miss is expected for subprocess-mode agents:
# cast-subagent-start-hook.sh exits early when CLAUDE_SUBPROCESS=1, so those
# agents never get a row in agent_runs. Truncation is still recorded with
# agent='unknown' — no hook_failure needed for this expected gap.

# Detection: prose Status block
# Recognized values: standard four (DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT) plus
# reviewer statuses (APPROVE|REQUEST_CHANGES) used by code-reviewer and pr-reviewer.
has_status = bool(re.search(
    r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)',
    response_text,
))
# Detection: JSON fenced status block
has_json = bool(re.search(
    r'```json\s+status[\s\S]*?"status"\s*:\s*"(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)"',
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
    import uuid as _uuid
    conn = sqlite3.connect(db, timeout=5)
    conn.execute(
        'INSERT INTO agent_truncations '
        '(session_id, agent_type, agent_id, last_line, timestamp, char_count, partial_work_log) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        (sess, agent, agent_id or None, last_line, ts, char_count, partial_work_log or None),
    )
    conn.commit()
    # P1 #1: also write a quality_gates row so truncation telemetry has a single source of truth.
    # Isolated in its own try so a missing quality_gates table (e.g., reduced test fixtures)
    # does not roll back the primary agent_truncations write.
    try:
        conn.execute(
            'INSERT INTO quality_gates (id, session_id, agent_name, timestamp, status_line, contract_passed, retry_count, gate_type) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            (str(_uuid.uuid4()), sess, agent, ts, 'TRUNCATED', 0, 0, 'truncation_detected'),
        )
        conn.commit()
    except Exception as _e:
        if log_hook_failure:
            log_hook_failure('cast-subagent-stop-hook:truncation_qg', -1, str(_e), sess)
    conn.close()
except Exception as e:
    try: conn.close()
    except Exception: pass
    if log_hook_failure:
        log_hook_failure('cast-subagent-stop-hook:truncation', -1, str(e), sess)
PYEOF
fi

# ── Step 2.4: Handoff block validation (WARN-only) ──────────────────────────
# Validates the typed ## Handoff schema in chained agent responses and logs
# violations to agent_protocol_violations for dashboard observability.
#
# False-positive guard (CRITICAL):
#   Block ABSENT + batch_id present  → violation="missing_handoff"   (chained, expected block)
#   Block ABSENT + batch_id absent   → log NOTHING                   (solo dispatch is fine)
#   Block PRESENT but unparseable    → violation="invalid_handoff_format"
#   Block PRESENT + bad schema       → violation="handoff_schema_violation", pattern=<field>
#
# Exemptions: agents in STATUS_CONTRACT_EXEMPT=1 are skipped entirely (same guard as
# Steps 2.1 / 3.5). Always exits 0 — warn-only, never blocks the hook pipeline.
if [[ "$STATUS_CONTRACT_EXEMPT" = "0" ]] && [[ -n "${CAST_STOP_RESPONSE_TEXT:-}" ]]; then
  python3 - 2>>"$HOOK_ERROR_LOG" <<'PYEOF' || true
import os, sys, re, json, importlib.util, subprocess
from datetime import datetime, timezone

# Resolved once here — used by all importlib.util loads and the redaction call below.
_hook_dir = os.environ.get('CAST_HOOK_DIR', os.path.expanduser('~/.claude/scripts'))

# ── Load cast_db for db_write ────────────────────────────────────────────────
def _noop_db_write(table, payload):
    return False

db_write = _noop_db_write
try:
    _db_spec = importlib.util.spec_from_file_location(
        'cast_db', os.path.join(_hook_dir, 'cast_db.py')
    )
    if _db_spec and _db_spec.loader:
        _cast_db = importlib.util.module_from_spec(_db_spec)
        _db_spec.loader.exec_module(_cast_db)
        db_write = _cast_db.db_write
except Exception:
    pass  # fall back to no-op; must not crash the hook pipeline

# ── Load cast_handoff_parser for validate_handoff ───────────────────────────
validate_handoff = None
try:
    _hp_spec = importlib.util.spec_from_file_location(
        'cast_handoff_parser', os.path.join(_hook_dir, 'cast_handoff_parser.py')
    )
    if _hp_spec and _hp_spec.loader:
        _hp_mod = importlib.util.module_from_spec(_hp_spec)
        _hp_spec.loader.exec_module(_hp_mod)
        validate_handoff = _hp_mod.validate_handoff
except Exception:
    pass

if validate_handoff is None:
    # Minimal inline fallback so the hook degrades gracefully if the file is missing
    _HANDOFF_RE = re.compile(r'## Handoff\s*\n([\s\S]+?)(?=\n## |\Z)')
    def validate_handoff(text):
        m = _HANDOFF_RE.search(text)
        if not m:
            return {'block_present': False, 'ok': False, 'violation': 'missing_handoff',
                    'pattern': None, 'detail': 'No ## Handoff block found', 'raw_excerpt': ''}
        block = m.group(1)
        # Minimal: check parseable and required fields present
        fields = {}
        for line in block.splitlines():
            line = line.strip()
            if ':' in line:
                k, _, v = line.partition(':')
                fields[k.strip().lower()] = v.strip()
        for req in ('files_changed', 'status', 'blockers'):
            if req not in fields or not fields[req]:
                return {'block_present': True, 'ok': False,
                        'violation': 'handoff_schema_violation',
                        'pattern': f'missing_field:{req}', 'detail': f'Missing {req}',
                        'raw_excerpt': block[:500]}
        if fields.get('status') not in ('DONE', 'DONE_WITH_CONCERNS', 'BLOCKED'):
            return {'block_present': True, 'ok': False,
                    'violation': 'handoff_schema_violation',
                    'pattern': f'invalid_value:status={fields.get("status", "")}',
                    'detail': 'Invalid status value', 'raw_excerpt': block[:500]}
        return {'block_present': True, 'ok': True, 'violation': None,
                'pattern': None, 'detail': None, 'raw_excerpt': block[:500]}

# ── Read environment ─────────────────────────────────────────────────────────
response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '') or ''
if not response_text.strip():
    sys.exit(0)

agent_type = os.environ.get('CAST_STOP_AGENT', 'unknown') or 'unknown'
agent_id   = os.environ.get('CAST_STOP_AGENT_ID', '') or ''
session_id = os.environ.get('CAST_STOP_SESSION', '') or ''

# Detect whether this agent was chained: batch_id present in raw SubagentStop input
# (same signal used by cast-agent-protocol-check.sh).
batch_id = None
raw_input = os.environ.get('CAST_STOP_INPUT', '') or ''
if raw_input:
    try:
        batch_id = json.loads(raw_input).get('batch_id')
    except Exception:
        pass

# ── Run validation ───────────────────────────────────────────────────────────
try:
    result = validate_handoff(response_text)
except Exception:
    sys.exit(0)  # parser error → degrade gracefully, no violation logged

block_present = result.get('block_present', False)
ok            = result.get('ok', True)
violation     = result.get('violation')
pattern       = result.get('pattern')
detail        = result.get('detail', '')
raw_excerpt   = result.get('raw_excerpt', '')

# Solo dispatch with absent block: not an error — log nothing.
# Only flag a missing block when the agent was part of a chain (batch_id set).
if not block_present and not batch_id:
    sys.exit(0)

# No violation: all good — nothing to log.
if ok:
    sys.exit(0)

# ── Redact raw_excerpt before storing (matches lines 1183-1191 in this hook) ──
# Same mechanism as the summary/concerns redaction: pipe through cast-redact.py
# --engine regex, extract redacted_text from JSON output. Falls back to the
# original text on any subprocess/parse failure — hook pipeline never blocked.
_excerpt_raw = (raw_excerpt or detail or '')[:500]
_excerpt_for_db = _excerpt_raw
try:
    _redact_result = subprocess.run(
        ['python3', os.path.join(_hook_dir, 'cast-redact.py'), '--engine', 'regex'],
        input=_excerpt_raw.encode(),
        capture_output=True,
        timeout=5,
    )
    if _redact_result.returncode == 0:
        _redacted = json.loads(_redact_result.stdout.decode())
        _excerpt_for_db = _redacted.get('redacted_text', _excerpt_raw)
except Exception:
    pass  # fall back to unredacted on any subprocess or parse failure

# ── Log violation ────────────────────────────────────────────────────────────
now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

payload = {
    'session_id': session_id,
    'agent_type': agent_type,
    'agent_id':   agent_id,
    'violation':  violation,
    'pattern':    pattern,
    'timestamp':  now_iso,
    'raw_excerpt': _excerpt_for_db,
}
# Remove None values to avoid SQLite type coercion issues
payload = {k: v for k, v in payload.items() if v is not None}

try:
    db_write('agent_protocol_violations', payload)
except Exception:
    pass  # never crash the hook pipeline

# Stderr WARN — no hookSpecificOutput banner (WARN-only contract)
print(
    f'[CAST-WARN] handoff_validation: {agent_type} {violation}'
    + (f' ({pattern})' if pattern else '')
    + ' — logged to cast.db',
    file=sys.stderr,
)
PYEOF
fi

# ── Step 2.5: Quality gate logging ──────────────────────────────────────────
# When a gate agent (code-reviewer, test-runner, security) finishes, extract its
# Status line and insert a row into quality_gates for dashboard observability.
#   DONE                 → pass  (contract_passed=1)
#   APPROVE              → pass  (contract_passed=1, reviewer alias for DONE)
#   DONE_WITH_CONCERNS   → warn
#   REQUEST_CHANGES      → warn  (reviewer alias for DONE_WITH_CONCERNS)
#   BLOCKED              → block
#   NEEDS_CONTEXT        → warn
# Other agents are skipped.
# Export the full agent output up-front — Step 3.5 (truncation detection)
# exports it again below; this earlier export lets quality-gate logging read it.
CAST_STOP_OUTPUT_FULL="${OUTPUT_FULL}"
export CAST_STOP_OUTPUT_FULL

if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  case "$AGENT_NAME" in
    code-reviewer|test-runner|security)
      python3 - <<'PYEOF' 2>>"$HOOK_ERROR_LOG" || true
import sqlite3, os, re, sys, uuid, datetime
sys.path.insert(0, os.environ.get('CAST_HOOK_DIR', os.path.expanduser('~/.claude/scripts')))
try:
    from cast_db import log_hook_failure
except Exception:
    log_hook_failure = None

db    = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent = os.environ.get('CAST_STOP_AGENT', '')
sess  = os.environ.get('CAST_STOP_SESSION', '')
out   = os.environ.get('CAST_STOP_OUTPUT_FULL', '')

if not agent or not db:
    raise SystemExit(0)

# Extract Status line from full output (no tail window — avoids FP for long Work Logs)
# Recognized: standard four + reviewer statuses (APPROVE|REQUEST_CHANGES)
m = re.search(r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)', out)
if not m:
    raise SystemExit(0)

status = m.group(1)
ts = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')

try:
    conn = sqlite3.connect(db, timeout=5)
    conn.execute(
        'INSERT INTO quality_gates (id, session_id, agent_name, timestamp, status_line, contract_passed, retry_count, gate_type) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        # APPROVE is pass-like (reviewer's DONE equivalent); REQUEST_CHANGES is non-pass
        (str(uuid.uuid4()), sess, agent, ts, status, 1 if status in ('DONE', 'APPROVE') else 0, 0, 'status_contract'),
    )
    conn.commit()
    conn.close()
except Exception as e:
    try: conn.close()
    except Exception: pass
    if log_hook_failure:
        log_hook_failure('cast-subagent-stop-hook:quality_gates', -1, str(e), sess)
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
# Delegates to cast-memory-facts-write.py (hardened: confidence cap, protection guard,
# non-destructive supersession). Skip gracefully if script is absent.
if [[ -n "${CAST_STOP_RESPONSE_TEXT:-}" ]] && command -v python3 >/dev/null 2>&1; then
  _FACTS_SCRIPT="$(dirname "$0")/cast-memory-facts-write.py"
  if [[ -f "$_FACTS_SCRIPT" ]]; then
    CAST_STOP_AGENT="${AGENT_NAME}" \
    CAST_STOP_RESPONSE_TEXT="${CAST_STOP_RESPONSE_TEXT}" \
    CAST_DB_PATH="${DB_PATH}" \
    CAST_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")" \
    python3 "$_FACTS_SCRIPT" 2>>"$HOOK_ERROR_LOG" || true
  fi
fi

# ── Step 2.8: Policy-gate completion record (v9 P-trust) ─────────────────────
# Records the agent's real self-reported terminal verdict (DONE/DONE_WITH_CONCERNS/
# BLOCKED/NEEDS_CONTEXT) to ~/.claude/agent-status/<agent>-<ts>.json.
# cast-git-guard.py (_agent_completed_this_session) is authoritative: it reads the
# MOST RECENT such record and clears requires_agent BLOCK policies only when that
# record has status DONE or DONE_WITH_CONCERNS.  A truncated agent (no recognized
# status) writes nothing → gate stays blocked.
if [[ "${STATUS_CONTRACT_EXEMPT:-1}" = "0" ]]; then
  # Take the LAST status of EITHER form across the whole output — prose
  # "Status: X" or JSON "status": "X" — so the true terminal verdict wins and an
  # earlier quoted status cannot pre-empt a later one (security: no prose/JSON pre-empt).
  # Longest-first order: DONE_WITH_CONCERNS before DONE prevents short-circuit.
  _GATE_MATCH=""
  _GATE_MATCH="$(printf '%s' "${OUTPUT_FULL}" |
    grep -oE '([*_]{0,2}[[:space:]]*Status:[[:space:]]*[*_]{0,2}[[:space:]]*|"status"[[:space:]]*:[[:space:]]*")(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)' 2>/dev/null |
    grep -oE 'DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT' | tail -1 || true)"

  # Write ONLY when a recognized status is found.  No match = no file = gate stays blocked.
  if [[ -n "$_GATE_MATCH" ]]; then
    if [[ -r "${HOME}/.claude/scripts/status-writer.sh" ]]; then
      # shellcheck source=/dev/null
      . "${HOME}/.claude/scripts/status-writer.sh" 2>/dev/null || true
    fi
    if command -v cast_write_status >/dev/null 2>&1; then
      # Neutral summary (defense-in-depth; the reader checks the structured
      # status field).  'subagent completion record' avoids any status keyword.
      cast_write_status \
        "$_GATE_MATCH" \
        "subagent completion record" \
        "$SAFE_AGENT" \
        "" \
        "" 2>/dev/null || true
    fi
  fi
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
# SKIP: agents exempt from the Status block contract (Claude Code built-ins, workflow-subagents)
# — they legitimately emit StructuredOutput or other non-CAST completion patterns.
if [[ "$STATUS_CONTRACT_EXEMPT" = "0" ]]; then
  # OUTPUT_FULL already extracted by the consolidated field-extraction block above.
  CAST_STOP_OUTPUT_FULL="${OUTPUT_FULL}"
  export CAST_STOP_OUTPUT_FULL

  # Three-value truncation classifier:
  #   0 = well-formed        (Status block present)
  #   1 = missing_formality  (>=200 chars, clean ending, no Status block — e.g. push-agent "all done")
  #   2 = actual_truncation  (structural signals: short, mid-word ending, trailing colon, odd code fence)
  TRUNC_CLASS="$(python3 - <<'PYEOF' 2>/dev/null
import re, os
output = os.environ.get('CAST_STOP_OUTPUT_FULL', '')
# Well-formed: Status block present (full output search, avoids FP for long Work Logs)
# Recognized values: standard four + reviewer statuses (APPROVE|REQUEST_CHANGES)
has_status = bool(re.search(r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)', output))
has_json = bool(re.search(r'"status"\s*:\s*"(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)"', output))
if has_status or has_json:
    print('0')
    raise SystemExit(0)
# Verdict-keyword exemption: deliberate short verdicts (e.g. "VERDICT: APPROVE",
# "Status: DONE") are well-formed even when under 200 chars.
# DONE_WITH_CONCERNS must be listed first in the alternation (longer match wins over bare DONE).
has_verdict = bool(re.search(r'\b(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)\b', output))
if has_verdict:
    print('0')
    raise SystemExit(0)
# No Status block — classify via structural truncation signals
length = len(output)
# Signal 1: short output (< 200 chars) — no room for a complete response
if length < 200:
    print('2')
    raise SystemExit(0)
tail = output[-100:]
# Signal 2: trailing colon suggests an incomplete statement
if re.search(r':\s*$', tail):
    print('2')
    raise SystemExit(0)
# Signal 3: unclosed code fence (odd count of triple backticks)
if output.count('```') % 2 != 0:
    print('2')
    raise SystemExit(0)
# Signal 4: mid-word ending — no terminal punctuation or whitespace before EOF
if not re.search(r'[.!?)\]}\s]\s*$', tail):
    print('2')
    raise SystemExit(0)
# Clean ending, long enough, no structural truncation signals → MISSING FORMALITY only
print('1')
PYEOF
  )"

  if [[ "${TRUNC_CLASS:-0}" = "2" ]] \
     && [[ -n "$CAST_STOP_OUTPUT_FULL" ]] \
     && [[ -n "${CAST_STOP_AGENT:-}" ]] \
     && [[ "${CAST_STOP_AGENT:-}" != "unknown" ]]; then
    # ACTUAL TRUNCATION: write file + fire banner
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

  elif [[ "${TRUNC_CLASS:-0}" = "1" ]] \
       && [[ -n "$CAST_STOP_OUTPUT_FULL" ]] \
       && [[ -n "${CAST_STOP_AGENT:-}" ]] \
       && [[ "${CAST_STOP_AGENT:-}" != "unknown" ]]; then
    # MISSING FORMALITY: suppress banner, log protocol violation (best-effort — never crash)
    python3 - <<'PYEOF' 2>/dev/null || true
import sqlite3, os
db    = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
agent = os.environ.get('CAST_STOP_AGENT', 'unknown')
sess  = os.environ.get('CAST_STOP_SESSION', '')
ts    = os.environ.get('CAST_STOP_TS_ISO', '')
out   = os.environ.get('CAST_STOP_OUTPUT_FULL', '')
try:
    # Table-existence guard: skip silently if DB absent or table not yet created
    if not os.path.isfile(db):
        raise SystemExit(0)
    conn = sqlite3.connect(db, timeout=2)
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if 'agent_protocol_violations' not in tables:
        conn.close()
        raise SystemExit(0)
    conn.execute(
        'INSERT INTO agent_protocol_violations '
        '(session_id, agent_type, violation, pattern, timestamp, raw_excerpt) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        (sess, agent, 'missing_formality', 'no_status_block', ts, out[-200:] if out else None),
    )
    conn.commit()
    conn.close()
except SystemExit:
    pass
except Exception:
    pass  # benign: never crash the hook pipeline on a protocol-violation write
PYEOF
  fi
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

# ── Step 4.5: Worktree anomaly check ─────────────────────────────────────────
# Handled by the dedicated `cast-subagent-worktree-check` SubagentStop hook entry
# (managed-settings.d/30-hooks-session.json). The previous inline invocation here
# caused a double-fire (double `git worktree list` + double worktree_anomalies write)
# per SubagentStop; removed 2026-06-18 (audit follow-up).

# ── Emit compressed hookSpecificOutput ───────────────────────────────────────
# Only emit when there is response text to parse. Excludes full response body
# from the payload — contains only: status, summary, concerns.
if [[ -n "${CAST_STOP_RESPONSE_TEXT:-}" ]]; then
  # Extract summary and concerns as Bash vars so they can be redacted before serialization.
  CAST_STOP_SUMMARY="$(python3 -c "
import os, re
text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')
m = re.search(r'Summary:\s*(.+)', text)
print(m.group(1).strip() if m else '')
" 2>/dev/null || echo "")"
  export CAST_STOP_SUMMARY

  CAST_STOP_CONCERNS="$(python3 -c "
import os, re, json
text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')
concerns = []
m = re.search(r'Concerns?:(.*?)(?=\n#|\n##|\nStatus:|\$)', text, re.DOTALL | re.IGNORECASE)
if m:
    for line in m.group(1).splitlines():
        line = line.strip().lstrip('- ').strip()
        if line:
            concerns.append(line)
print(json.dumps(concerns))
" 2>/dev/null || echo "[]")"
  export CAST_STOP_CONCERNS

  # Redact PII (e.g. API keys, emails) from summary and concerns before serialization.
  # HOOK_DIR is exported at script top — points to the directory containing cast-redact.py.
  # Fallback: if cast-redact.py is unavailable, use raw values (|| passthrough is intentional).
  # --engine regex: regex covers all credential/secret patterns; spaCy NER (person/org) is
  # lower-stakes for a DB summary field — avoids 0.5–3s Presidio startup cost on this hot path.
  SUMMARY_REDACTED="$(echo "${CAST_STOP_SUMMARY}" | python3 "${HOOK_DIR}/cast-redact.py" --engine regex --field redacted_text 2>/dev/null || echo "${CAST_STOP_SUMMARY}")"
  CONCERNS_REDACTED="$(echo "${CAST_STOP_CONCERNS}" | python3 "${HOOK_DIR}/cast-redact.py" --engine regex --field redacted_text 2>/dev/null || echo "${CAST_STOP_CONCERNS}")"
  export CAST_STOP_SUMMARY_REDACTED="$SUMMARY_REDACTED"
  export CAST_STOP_CONCERNS_REDACTED="$CONCERNS_REDACTED"

  CAST_STOP_RESPONSE_TEXT="${CAST_STOP_RESPONSE_TEXT}" python3 - <<'PYEOF'
import os, sys, re, json

text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')

# Extract Status — longest-first alternation; leading/trailing emphasis tolerated
status_match = re.search(
    r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)[*_]{0,2}',
    text,
)
status = status_match.group(1) if status_match else 'UNKNOWN'

# Use pre-redacted summary and concerns (PII already stripped by cast-redact.py)
summary_raw = os.environ.get('CAST_STOP_SUMMARY_REDACTED', '')
concerns_raw = os.environ.get('CAST_STOP_CONCERNS_REDACTED', '[]')

# summary is a plain string; concerns is a JSON array string
summary = summary_raw

try:
    concerns = json.loads(concerns_raw)
    if not isinstance(concerns, list):
        concerns = []
except Exception:
    concerns = []

compressed = {
    'status': status,
    'summary': summary,
    'concerns': concerns,
}
output = json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'SubagentStop',
        'additionalContext': json.dumps(compressed),
    }
})
print(output)
PYEOF
fi

exit 0
