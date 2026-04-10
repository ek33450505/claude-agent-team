#!/bin/bash
# cast-worktree-create-hook.sh — WorktreeCreate hook
# Fires when a new git worktree is created by Claude Code.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Ensure CAST environment is accessible from the new worktree
#   3. Symlink scripts/ and agent-memory paths into worktree context
#
# Stdin JSON fields (WorktreeCreate):
#   worktree_path — path to the new worktree
#   branch        — branch checked out in worktree
#   session_id    — current session
#
# Exit codes:
#   0 — always (hook must not block)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || _log_error "worktree-create setup failed (exit $?)"
import json, os, subprocess
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

worktree_path = data.get("worktree_path", "")
branch        = data.get("branch", "")
session_id    = data.get("session_id", os.environ.get("CLAUDE_SESSION_ID", "unknown"))
now           = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if not worktree_path or not os.path.isdir(worktree_path):
    import sys; sys.exit(0)

# Ensure .claude directory exists in worktree
wt_claude = os.path.join(worktree_path, ".claude")
os.makedirs(wt_claude, exist_ok=True)

# Symlink key CAST directories if not already present
cast_home = os.path.expanduser("~/.claude")
links = {
    "scripts": os.path.join(cast_home, "scripts"),
    "agent-memory-local": os.path.join(cast_home, "agent-memory-local"),
    "skills": os.path.join(cast_home, "skills"),
}

for name, target in links.items():
    link_path = os.path.join(wt_claude, name)
    if not os.path.exists(link_path) and os.path.exists(target):
        try:
            os.symlink(target, link_path)
        except OSError:
            pass  # Non-fatal

# Log to cast.db
import sqlite3
db_path = os.path.join(cast_home, "cast.db")
if os.path.exists(db_path):
    try:
        con = sqlite3.connect(db_path, timeout=3)
        con.execute("""
            CREATE TABLE IF NOT EXISTS worktree_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                timestamp TEXT,
                worktree_path TEXT,
                branch TEXT,
                event_type TEXT
            )
        """)
        con.execute(
            "INSERT INTO worktree_events (session_id, timestamp, worktree_path, branch, event_type) VALUES (?, ?, ?, ?, ?)",
            (session_id, now, worktree_path, branch, "created"),
        )
        con.commit()
        con.close()
    except Exception:
        pass  # Non-fatal

output = {
    "hookSpecificOutput": {
        "level": "info",
        "message": f"CAST environment linked into worktree: {worktree_path}"
    }
}
print(json.dumps(output))
PYEOF

exit 0
