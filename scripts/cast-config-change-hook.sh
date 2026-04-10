#!/bin/bash
# cast-config-change-hook.sh — ConfigChange hook
# Fires when Claude Code configuration is modified.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Log config changes to cast.db
#   3. Warn on permission or env changes via hookSpecificOutput
#
# Stdin JSON fields (ConfigChange):
#   config_key   — the config key that changed
#   old_value    — previous value
#   new_value    — new value
#   source       — where the change originated
#
# Exit codes:
#   0 — always (hook must not block)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || _log_error "config-change DB block failed (exit $?)"
import json, os, sqlite3
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

config_key = data.get("config_key", "unknown")
old_value  = json.dumps(data.get("old_value", ""))
new_value  = json.dumps(data.get("new_value", ""))
source     = data.get("source", "unknown")
now        = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
session_id = data.get("session_id", os.environ.get("CLAUDE_SESSION_ID", "unknown"))

db_path = os.path.expanduser("~/.claude/cast.db")
if not os.path.exists(db_path):
    import sys; sys.exit(0)

try:
    con = sqlite3.connect(db_path, timeout=3)
    con.execute("""
        CREATE TABLE IF NOT EXISTS config_changes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            timestamp TEXT,
            config_key TEXT,
            old_value TEXT,
            new_value TEXT,
            source TEXT
        )
    """)
    con.execute(
        "INSERT INTO config_changes (session_id, timestamp, config_key, old_value, new_value, source) VALUES (?, ?, ?, ?, ?, ?)",
        (session_id, now, config_key, old_value, new_value, source),
    )
    con.commit()
    con.close()
except Exception as e:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_dir = os.path.expanduser("~/.claude/logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
        lf.write(f"[{ts}] ERROR cast-config-change-hook.sh: DB INSERT failed: {type(e).__name__}: {e}\n")

# Warn on sensitive changes
sensitive_keys = ["permissions", "env", "sandbox", "allowedTools"]
is_sensitive = any(k in config_key.lower() for k in sensitive_keys)

if is_sensitive:
    output = {
        "hookSpecificOutput": {
            "level": "warn",
            "message": f"Sensitive config changed: {config_key} (source: {source})"
        }
    }
    print(json.dumps(output))
PYEOF

exit 0
