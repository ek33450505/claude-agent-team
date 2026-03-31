#!/bin/bash
# cast-tool-failure-hook.sh — PostToolUseFailure hook
# Fires when a tool call fails.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Log failure metadata to ~/.claude/cast/tool-failures.jsonl
#   3. Log to cast.db routing_events table
#
# Stdin JSON fields (PostToolUseFailure):
#   session_id  — current session ID
#   tool_name   — name of the tool that failed
#   tool_input  — input passed to the tool (may be large)
#   error       — the failure message
#
# Exit codes:
#   0 — always

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set +e

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || true
import json, os
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

session_id    = data.get("session_id", "unknown")
tool_name     = data.get("tool_name", "unknown")
tool_input    = str(data.get("tool_input", ""))[:200]
error_text    = str(data.get("error", ""))
error_preview = error_text[:200]
input_preview = tool_input[:100]

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Log to tool-failures.jsonl
entry = {
    "timestamp":     iso_ts,
    "session_id":    session_id,
    "tool_name":     tool_name,
    "error_preview": error_preview,
    "input_preview": input_preview,
}

log_path = os.path.expanduser("~/.claude/cast/tool-failures.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception:
    pass

# Log to cast.db routing_events
db_path = os.path.expanduser("~/.claude/cast.db")
data_json = json.dumps({"tool_name": tool_name, "error_preview": error_preview})
try:
    import sqlite3 as _sqlite3
    con = _sqlite3.connect(db_path, timeout=3)
    con.execute(
        "INSERT INTO routing_events (timestamp, session_id, event_type, data) VALUES (?, ?, ?, ?)",
        (iso_ts, session_id, "tool_failure", data_json),
    )
    con.commit()
    con.close()
except Exception:
    pass
PYEOF

exit 0
