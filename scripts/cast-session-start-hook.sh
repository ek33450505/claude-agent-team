#!/bin/bash
# cast-session-start-hook.sh — SessionStart hook
# Fires once when a new Claude Code session starts.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Write CAST env vars to $CLAUDE_ENV_FILE if set
#   3. Log session start to ~/.claude/cast/session-starts.jsonl
#
# Stdin JSON fields (SessionStart):
#   session_id — the new session's ID
#   cwd        — working directory of the session
#
# Exit codes:
#   0 — always (hook must not block the session)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || true
import json, os
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

session_id = data.get("session_id", "unknown")
cwd        = data.get("cwd", "")

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Write env vars to $CLAUDE_ENV_FILE if set
env_file = os.environ.get("CLAUDE_ENV_FILE", "")
if env_file:
    try:
        parent = os.path.dirname(env_file)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(env_file, "a") as f:
            f.write(f"CAST_SESSION_ID={session_id}\n")
            f.write(f"CAST_SESSION_CWD={cwd}\n")
            f.write(f"CAST_SESSION_START_TS={iso_ts}\n")
    except Exception:
        pass

# Log to session-starts.jsonl
entry = {
    "timestamp":  iso_ts,
    "session_id": session_id,
    "cwd":        cwd,
}

log_path = os.path.expanduser("~/.claude/cast/session-starts.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception:
    pass
PYEOF

CAST_INPUT="$INPUT" python3 - <<'PYEOF2' || true
import json, os, sqlite3 as _sqlite3
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

session_id = data.get("session_id", "unknown")
cwd        = data.get("cwd", "")
now        = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
project    = os.path.basename(cwd.rstrip('/')) if cwd else "unknown"

db_path = os.path.expanduser("~/.claude/cast.db")
if not os.path.exists(db_path):
    import sys; sys.exit(0)

try:
    con = _sqlite3.connect(db_path, timeout=3)
    con.execute(
        "INSERT OR IGNORE INTO sessions (id, project, project_root, started_at) VALUES (?, ?, ?, ?)",
        (session_id, project, cwd, now),
    )
    con.commit()
    con.close()
except Exception:
    pass
PYEOF2

exit 0
