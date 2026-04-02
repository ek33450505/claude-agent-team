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

# _log_error: append a structured error line to hook-errors.log (never fails itself)
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || _log_error "session-start JSONL block failed (exit $?)"
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
    except Exception as e:
        import sys, os as _os
        from datetime import datetime, timezone
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        log_dir = _os.path.expanduser("~/.claude/logs")
        _os.makedirs(log_dir, exist_ok=True)
        with open(_os.path.join(log_dir, "hook-errors.log"), "a") as lf:
            lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: env_file write failed: {e}\n")

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
except Exception as e:
    import os as _os
    from datetime import datetime, timezone
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_dir = _os.path.expanduser("~/.claude/logs")
    _os.makedirs(log_dir, exist_ok=True)
    with open(_os.path.join(log_dir, "hook-errors.log"), "a") as lf:
        lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: session-starts.jsonl write failed: {e}\n")
PYEOF

CAST_INPUT="$INPUT" python3 - <<'PYEOF2' || _log_error "session-start DB block failed (exit $?)"
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
except Exception as e:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_dir = os.path.expanduser("~/.claude/logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
        lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: DB INSERT failed: {type(e).__name__}: {e}\n")
PYEOF2

# OTEL export wiring
# If OTEL_EXPORTER_OTLP_ENDPOINT is set, configure OTLP exporters; otherwise use console.
if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  echo "OTEL_METRICS_EXPORTER=otlp" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
  echo "OTEL_LOGS_EXPORTER=otlp" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
else
  echo "OTEL_METRICS_EXPORTER=console" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
fi

exit 0
