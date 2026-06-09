#!/bin/bash
# cast-response-completeness-hook.sh — CAST SubagentStop hook for truncation detection
# Hook event: SubagentStop
#
# Fires when a subagent stops and checks whether its response contains a valid
# Status block. Missing Status blocks may indicate truncation or incomplete execution.
#
# Responsibilities:
#   1. Parse agent response from SubagentStop stdin
#   2. Check for Status: (DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT) pattern
#   3. If missing: log warning to ~/.claude/logs/hook-errors.log
#   4. Write completeness_events entry to cast.db (CREATE TABLE IF NOT EXISTS)
#   5. Exit 0 always (do not block the pipeline)
#
# Stdin JSON fields (SubagentStop):
#   agent_type (or agent_name)  — name of the subagent
#   last_assistant_message      — agent's final output text
#   output                       — fallback to this if last_assistant_message absent
#
# Exit codes:
#   0 — always (hook must not block the parent session)
#
# Installation (add to ~/.claude/settings.json under "hooks"):
#   "SubagentStop": [
#     {
#       "id": "cast-response-completeness",
#       "hooks": [
#         {
#           "type": "command",
#           "command": "bash ~/Projects/personal/claude-agent-team/scripts/cast-response-completeness-hook.sh",
#           "timeout": 5,
#           "async": true
#         }
#       ]
#     }
#   ]

# SubagentStop fires inside the parent session — CLAUDE_SUBPROCESS is not set.
# Never fail loudly — a broken hook must not interrupt the parent session.
set +e

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}

LOGS_DIR="${HOME}/.claude/logs"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

mkdir -p "$LOGS_DIR" 2>/dev/null || true

# Read stdin once
INPUT="$(cat 2>/dev/null)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse fields from JSON input via env var (never interpolate into Python source)
export CAST_COMP_INPUT="$INPUT"

PARSED="$(python3 - <<'PYEOF' 2>/dev/null
import sys, json, os

raw = os.environ.get('CAST_COMP_INPUT', '')
if not raw:
    print(json.dumps({"error": "no input"}))
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print(json.dumps({"error": "invalid json"}))
    sys.exit(0)

# Extract agent name and response text
agent_name = data.get("agent_type") or data.get("agent_name") or data.get("subagent_name") or "unknown"
output_text = data.get("last_assistant_message") or data.get("output") or ""

result = {
    "agent": agent_name,
    "output": output_text,
    "output_snippet": output_text[:200] if output_text else "",
}
print(json.dumps(result))
PYEOF
)" || true

if [ -z "$PARSED" ]; then
  exit 0
fi

# Extract individual fields
export CAST_COMP_PARSED="$PARSED"

AGENT="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_COMP_PARSED','{}')); print(d.get('agent','unknown'))" 2>/dev/null || echo "unknown")"
OUTPUT="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_COMP_PARSED','{}')); print(d.get('output',''))" 2>/dev/null || echo "")"
OUTPUT_SNIPPET="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_COMP_PARSED','{}')); print(d.get('output_snippet',''))" 2>/dev/null || echo "")"

# Shared Status-contract helper (single source of truth; inline fallback if absent)
if [ -r "${HOME}/.claude/scripts/cast-status-contract.sh" ]; then
  # shellcheck source=/dev/null
  . "${HOME}/.claude/scripts/cast-status-contract.sh"
fi
if ! command -v cast_status_exempt_agent >/dev/null 2>&1; then
  cast_status_exempt_agent() { case "${1:-}" in general-purpose|Explore|Plan|claude|statusline-setup|output-style-setup|unknown|"") return 0;; *workflow-subagent*) return 0;; *) return 1;; esac; }
  cast_output_lacks_prose() { [ -z "$(printf '%s' "${1:-}" | tr -d '[:space:]')" ]; }
fi

STATUS_CONTRACT_EXEMPT="0"
if cast_status_exempt_agent "$AGENT"; then
  STATUS_CONTRACT_EXEMPT="1"
fi

# Check for Status block in the full output text
# Matches either the human-readable form (Status: DONE) or the JSON form ("status": "DONE")
# NOTE: Searches the full response — no line-count window — so Status blocks near the top
# (before a long Work Log section) are not missed.
HAS_STATUS="$(python3 - <<'PYEOF' 2>/dev/null
import re, os, json
output = os.environ.get('CAST_COMP_PARSED', '{}')
try:
    data = json.loads(output)
    text = data.get('output', '')
except Exception:
    text = ''

human_status = bool(re.search(r'[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)', text))
json_status = bool(re.search(r'"status"\s*:\s*"(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)"', text))
has_status = human_status or json_status
print('1' if has_status else '0')
PYEOF
)" || echo "0"

if [ "$STATUS_CONTRACT_EXEMPT" = "0" ] && [ "$HAS_STATUS" != "1" ] && [ -n "$OUTPUT" ]; then
  # Missing Status block — log warning and write to database
  TIMESTAMP_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat().replace('+00:00','')+'Z')")"

  # Determine severity: HIGH if output ends with incomplete phrase (Perfect!/Let me/I'll/Now/etc)
  # Use Python for robust detection of trailing incomplete phrases
  SEVERITY="$(python3 - <<'SEVEOF' 2>/dev/null
import re, os
output = os.environ.get('CAST_COMP_PARSED', '{}')
try:
    import json
    data = json.loads(output)
    text = data.get('output', '')
except Exception:
    text = ''

# Check if text ends with incomplete phrases
if re.search(r"(Perfect!|Let me|I'll|Now|I'm|I am)\s*$", text, re.IGNORECASE):
    print('HIGH')
else:
    print('MEDIUM')
SEVEOF
  )" || echo "MEDIUM"

  # Log to hook-errors.log
  _log_error "[CAST COMPLETENESS] Agent response missing Status block. Possible truncation. Agent: ${AGENT}. Severity: ${SEVERITY}. Timestamp: ${TIMESTAMP_ISO}."

  # Write to cast.db completeness_events table (idempotent CREATE TABLE IF NOT EXISTS)
  if command -v sqlite3 >/dev/null 2>&1; then
    export CAST_COMP_AGENT="$AGENT"
    export CAST_COMP_TIMESTAMP="$TIMESTAMP_ISO"
    export CAST_COMP_SEVERITY="$SEVERITY"
    export CAST_COMP_SNIPPET="$OUTPUT_SNIPPET"
    export CAST_COMP_DB="$DB_PATH"

    python3 - <<'PYEOF' 2>>"${HOME}/.claude/logs/hook-errors.log" || true
import sqlite3, os
from datetime import datetime, timezone

db = os.path.expanduser(os.environ.get('CAST_COMP_DB', '~/.claude/cast.db'))
agent = os.environ.get('CAST_COMP_AGENT', 'unknown')
timestamp = os.environ.get('CAST_COMP_TIMESTAMP', '')
severity = os.environ.get('CAST_COMP_SEVERITY', 'MEDIUM')
snippet = os.environ.get('CAST_COMP_SNIPPET', '')

if not db or not agent:
    raise SystemExit(0)

try:
    conn = sqlite3.connect(db, timeout=5)
    cur = conn.cursor()

    # Create table if not exists (idempotent)
    cur.execute('''
        CREATE TABLE IF NOT EXISTS completeness_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent TEXT NOT NULL,
            truncated_at TEXT NOT NULL,
            snippet TEXT,
            severity TEXT DEFAULT 'MEDIUM',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    ''')

    # Insert event
    cur.execute(
        'INSERT INTO completeness_events (agent, truncated_at, snippet, severity) '
        'VALUES (?, ?, ?, ?)',
        (agent, timestamp, snippet, severity),
    )

    conn.commit()
    conn.close()
except Exception as e:
    # Log but don't crash
    pass
PYEOF
  fi
fi

exit 0
