#!/bin/bash
# cast-user-prompt-hook.sh — UserPromptSubmit hook
# Fires each time the user submits a prompt.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Log prompt metadata (never full text) to ~/.claude/cast/user-prompts.jsonl
#   3. Log to cast.db routing_events table
#
# Stdin JSON fields (UserPromptSubmit):
#   session_id — current session ID
#   prompt     — the user's raw prompt text
#
# Exit codes:
#   0 — always (never block the session — do not exit 2)

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

session_id     = data.get("session_id", "unknown")
prompt_text    = data.get("prompt", "")
prompt_length  = len(prompt_text)
prompt_preview = prompt_text[:120]

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Log to user-prompts.jsonl
entry = {
    "timestamp":      iso_ts,
    "session_id":     session_id,
    "prompt_length":  prompt_length,
    "prompt_preview": prompt_preview,
}

log_path = os.path.expanduser("~/.claude/cast/user-prompts.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception:
    pass

# Log to cast.db routing_events
db_path = os.path.expanduser("~/.claude/cast.db")
prompt_preview_db = prompt_text[:80]
project = os.path.basename(os.getcwd().rstrip('/')) or "unknown"
data_json = json.dumps({"prompt_length": prompt_length, "prompt_preview": prompt_preview})
try:
    import sqlite3 as _sqlite3
    con = _sqlite3.connect(db_path, timeout=3)
    con.execute(
        "INSERT INTO routing_events (timestamp, session_id, event_type, prompt_preview, action, project, data) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (iso_ts, session_id, "user_prompt_submit", prompt_preview_db, "user_prompt_submit", project, data_json),
    )
    con.commit()
    con.close()
except Exception:
    pass
PYEOF

exit 0
