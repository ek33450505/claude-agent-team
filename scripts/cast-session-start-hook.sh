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

session_id = data.get("session_id", "")
cwd        = data.get("cwd", "")
now        = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
project    = os.path.basename(cwd.rstrip('/')) if cwd else "unknown"

# Guard: skip INSERT when session_id is missing/empty — a NULL or empty PK
# produces unresolvable rows (4 found in live DB audit, Phase 5 Wave 2)
if not session_id:
    import sys; sys.exit(0)

db_path = os.path.expanduser("~/.claude/cast.db")
if not os.path.exists(db_path):
    import sys; sys.exit(0)

try:
    con = _sqlite3.connect(db_path, timeout=3)
    # Add status column if missing (idempotent — silently ignored if already present)
    try:
        con.execute("ALTER TABLE sessions ADD COLUMN status TEXT DEFAULT 'ended'")
        con.commit()
    except Exception:
        pass
    con.execute(
        "INSERT OR IGNORE INTO sessions (id, project, project_root, started_at, status) VALUES (?, ?, ?, ?, 'active')",
        (session_id, project, cwd, now),
    )
    # If row already existed (OR IGNORE), update status to active
    con.execute(
        "UPDATE sessions SET status = 'active' WHERE id = ? AND status != 'active'",
        (session_id,),
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

# Export pane_id for use in the next python block
export CAST_PANE_ID_FOR_HOOK="${CAST_DESKTOP_PANE_ID:-}"

CAST_INPUT="$INPUT" python3 - <<'PYEOF3' || _log_error "session-start pane-bindings block failed (exit $?)"
import json, os, sqlite3 as _sqlite3
from datetime import datetime, timezone

# Early exit if no pane_id provided
pane_id = os.environ.get("CAST_PANE_ID_FOR_HOOK", "").strip()
if not pane_id:
    import sys; sys.exit(0)

# Parse session_id and cwd from CAST_INPUT
raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

session_id = data.get("session_id", "unknown")
cwd = data.get("cwd", "")

db_path = os.path.expanduser("~/.claude/cast.db")
if not os.path.exists(db_path):
    import sys; sys.exit(0)

try:
    con = _sqlite3.connect(db_path, timeout=3)
    # Create pane_bindings table if missing
    con.execute("""
        CREATE TABLE IF NOT EXISTS pane_bindings (
            pane_id TEXT PRIMARY KEY,
            session_id TEXT,
            started_at INTEGER,
            ended_at INTEGER,
            project_path TEXT
        )
    """)
    # Insert or update pane binding
    con.execute(
        """
        INSERT INTO pane_bindings (pane_id, session_id, started_at, project_path)
        VALUES (?, ?, strftime('%s','now'), ?)
        ON CONFLICT(pane_id) DO UPDATE SET
            session_id=excluded.session_id,
            started_at=excluded.started_at,
            project_path=excluded.project_path,
            ended_at=NULL
        """,
        (pane_id, session_id, cwd),
    )
    con.commit()
    con.close()
except Exception as e:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_dir = os.path.expanduser("~/.claude/logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
        lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: pane-bindings INSERT failed: {type(e).__name__}: {e}\n")
PYEOF3

# Notify the Cast Desktop backend of the pane binding
if [ -n "${CAST_DESKTOP_PANE_ID:-}" ]; then
  curl -s -X POST "http://localhost:3001/api/pane-bindings/notify" \
    -H "Content-Type: application/json" \
    -d "{\"paneId\": \"${CAST_DESKTOP_PANE_ID}\"}" \
    --max-time 2 >/dev/null 2>&1 || true
fi

# OTEL export wiring (Phase 12 — native OpenTelemetry, opt-in via OTLP endpoint)
# Native OTel is OFF by default. Setting OTEL_EXPORTER_OTLP_ENDPOINT turns it on and
# routes telemetry to that collector. With no endpoint, telemetry stays disabled so
# interactive sessions are never spammed with console metric dumps.
if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  echo "CLAUDE_CODE_ENABLE_TELEMETRY=1" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
  echo "OTEL_METRICS_EXPORTER=otlp" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
  echo "OTEL_LOGS_EXPORTER=otlp" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
fi

exit 0
