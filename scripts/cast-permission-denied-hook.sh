#!/bin/bash
# cast-permission-denied-hook.sh — PermissionDenied hook
# Fires when auto-mode denies a tool invocation.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Log all denials to cast.db with tool name and reason
#
# Stdin JSON fields (PermissionDenied):
#   tool_name  — the tool that was denied
#   reason     — why it was denied
#   session_id — current session
#
# Exit codes:
#   0 — always (hook must not block)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || _log_error "permission-denied DB block failed (exit $?)"
import json, os, sqlite3
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

tool_name  = data.get("tool_name", "unknown")
reason     = data.get("reason", "")
session_id = data.get("session_id", os.environ.get("CLAUDE_SESSION_ID", "unknown"))
now        = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

db_path = os.path.expanduser("~/.claude/cast.db")
if not os.path.exists(db_path):
    import sys; sys.exit(0)

try:
    con = sqlite3.connect(db_path, timeout=3)
    con.execute("""
        CREATE TABLE IF NOT EXISTS permission_denials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            timestamp TEXT,
            tool_name TEXT,
            reason TEXT
        )
    """)
    con.execute(
        "INSERT INTO permission_denials (session_id, timestamp, tool_name, reason) VALUES (?, ?, ?, ?)",
        (session_id, now, tool_name, reason),
    )
    con.commit()
    con.close()
except Exception as e:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_dir = os.path.expanduser("~/.claude/logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
        lf.write(f"[{ts}] ERROR cast-permission-denied-hook.sh: DB INSERT failed: {type(e).__name__}: {e}\n")
PYEOF

exit 0
