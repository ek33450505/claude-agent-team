#!/bin/bash
# cast-worktree-create-hook.sh — WorktreeCreate hook
# Fires when a new git worktree is created by Claude Code.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Ensure CAST environment is accessible from the new worktree
#   3. Symlink scripts/ and agent-memory paths into worktree context
#   4. Swarm-aware: insert teammate_runs row if CAST_SWARM_ID is set
#   5. Copy spawn preamble to .claude/CLAUDE.md if CAST_SPAWN_PREAMBLE is set
#   6. Log worktree_created event to teammate_messages
#
# Stdin JSON fields (WorktreeCreate):
#   worktree_path — path to the new worktree
#   branch        — branch checked out in worktree
#   session_id    — current session
#
# Env vars (swarm mode):
#   CAST_SWARM_ID       — swarm session ID (triggers swarm DB inserts)
#   CAST_SPAWN_PREAMBLE — path to preamble file to copy into .claude/CLAUDE.md
#   CAST_AGENT_ROLE     — agent role name (for teammate_runs row)
#   CAST_AGENT_DEF      — agent definition (e.g. "code-writer")
#
# Exit codes:
#   0 — always (hook must not block)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" \
CAST_SWARM_ID="${CAST_SWARM_ID:-}" \
CAST_SPAWN_PREAMBLE="${CAST_SPAWN_PREAMBLE:-}" \
CAST_AGENT_ROLE="${CAST_AGENT_ROLE:-}" \
CAST_AGENT_DEF="${CAST_AGENT_DEF:-}" \
python3 - <<'PYEOF' || _log_error "worktree-create setup failed (exit $?)"
import json, os, shutil, sqlite3, uuid
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

worktree_path  = data.get("worktree_path", "")
branch         = data.get("branch", "")
session_id     = data.get("session_id", os.environ.get("CLAUDE_SESSION_ID", "unknown"))
swarm_id       = os.environ.get("CAST_SWARM_ID", "")
spawn_preamble = os.environ.get("CAST_SPAWN_PREAMBLE", "")
agent_role     = os.environ.get("CAST_AGENT_ROLE", "")
agent_def      = os.environ.get("CAST_AGENT_DEF", "")
now            = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
cast_home      = os.path.expanduser("~/.claude")
db_path        = os.path.join(cast_home, "cast.db")

if not worktree_path or not os.path.isdir(worktree_path):
    import sys; sys.exit(0)

# Ensure .claude directory exists in worktree
wt_claude = os.path.join(worktree_path, ".claude")
os.makedirs(wt_claude, exist_ok=True)

# Symlink key CAST directories if not already present
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

# Copy spawn preamble into .claude/CLAUDE.md if CAST_SPAWN_PREAMBLE is set
if spawn_preamble and os.path.isfile(spawn_preamble):
    try:
        dest = os.path.join(wt_claude, "CLAUDE.md")
        shutil.copy2(spawn_preamble, dest)
    except Exception:
        pass  # Non-fatal

# Swarm-aware DB operations
if os.path.exists(db_path):
    try:
        con = sqlite3.connect(db_path, timeout=3)
        cur = con.cursor()

        # Insert teammate_runs row if swarm context is present
        if swarm_id:
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_runs'")
            if cur.fetchone():
                run_id = str(uuid.uuid4())[:16]
                cur.execute(
                    '''INSERT OR IGNORE INTO teammate_runs
                       (id, swarm_id, agent_role, agent_def, worktree, status, started_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?)''',
                    (run_id, swarm_id, agent_role or "unknown", agent_def or "unknown",
                     worktree_path, "idle", now)
                )

        # Log worktree_created event to teammate_messages
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_messages'")
        if cur.fetchone():
            cur.execute(
                '''INSERT INTO teammate_messages
                   (id, swarm_id, from_agent, to_agent, message_type, payload, timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?)''',
                (
                    str(uuid.uuid4())[:16],
                    swarm_id or None,
                    agent_role or "worktree",
                    None,
                    "worktree_created",
                    json.dumps({"worktree_path": worktree_path, "branch": branch, "session_id": session_id}),
                    now,
                )
            )

        # Also log to worktree_events for backward compatibility
        con.execute("""
            CREATE TABLE IF NOT EXISTS worktree_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT, timestamp TEXT, worktree_path TEXT, branch TEXT, event_type TEXT
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

print(json.dumps({
    "hookSpecificOutput": {
        "level": "info",
        "message": f"CAST environment linked into worktree: {worktree_path}"
    }
}))
PYEOF

exit 0
