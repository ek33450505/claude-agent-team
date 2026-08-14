#!/bin/bash
# cast-teammate-idle-hook.sh — TeammateIdle hook (Claude Code experimental Agent Teams)
#
# EXPERIMENTAL: gated by CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS; dormant until that flag
# is enabled in a session. This hook is logging-only / advisory / fail-open — it NEVER
# exits 2 (exit 2 would keep the teammate working; this hook must never block resumption).
#
# Verified payload fields (docs.claude.com/en/hooks TeammateIdle):
#   session_id, transcript_path, cwd, hook_event_name,
#   teammate_name, agent_id, agent_type
#   NO task_id / task_subject in this event.
#
# Writes to:
#   - ~/.claude/cast/events/<ts>-<id>-teammate-idle.json  (immutable event log)
#   - cast.db swarm_sessions + teammate_runs (dormant tables re-populated when enabled)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set +e

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

set -euo pipefail

# shellcheck source=cast-sqlite-lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Existence-checked before sourcing — see cast-guard-lib.sh header (bash 3.2 + set -e
# makes `source` of a missing file fatal even left-of-`||`).
if [[ -f "${SCRIPT_DIR}/cast-sqlite-lib.sh" ]]; then
  source "${SCRIPT_DIR}/cast-sqlite-lib.sh" 2>/dev/null || true
fi
# shellcheck source=cast-hook-lib.sh
if [[ -f "${SCRIPT_DIR}/cast-hook-lib.sh" ]]; then
  source "${SCRIPT_DIR}/cast-hook-lib.sh" 2>/dev/null || true
fi

cast_hook_read_stdin
cast_hook_db_path

CAST_INPUT="$INPUT" DB_PATH_VAL="$DB_PATH" python3 - <<'PYEOF' || true
import json, os, sqlite3, uuid
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", ""); db_path = os.environ.get("DB_PATH_VAL", "")
try: data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

session_id = data.get("session_id", "unknown")
teammate   = data.get("teammate_name", "") or ""
agent_id   = data.get("agent_id", "") or ""
agent_type = data.get("agent_type", "") or ""
cwd = data.get("cwd", ""); project = os.path.basename(cwd) if cwd else ""
# team_id: session-derived id (team_name deprecated in v2.1.178; no longer emitted by native). cast-task-completed-hook.sh uses the identical derivation.
team_id = "session-" + session_id[:8] if session_id and session_id != "unknown" else ""
now = datetime.now(timezone.utc); iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# 1) immutable event log (works even without cast.db)
events_dir = os.path.expanduser("~/.claude/cast/events")
try:
    os.makedirs(events_dir, exist_ok=True)
    event = {"id": str(uuid.uuid4()), "timestamp": iso_ts, "type": "teammate_idle",
             "session_id": session_id, "team_id": team_id, "agent_id": agent_id,
             "agent_type": agent_type, "teammate_name": teammate, "project": project,
             "schema_version": 1, "source": "native-agent-teams"}
    short_id = str(uuid.uuid4())[:8]
    with open(os.path.join(events_dir, f"{iso_ts}-{short_id}-teammate-idle.json"), "w") as f:
        json.dump(event, f, indent=2); f.write("\n")
except Exception: pass

# 2) repopulate dormant swarm_sessions + teammate_runs
NOTES = json.dumps({"source": "native-agent-teams", "schema_version": 1})
if db_path and os.path.exists(db_path) and team_id:
    try:
        conn = sqlite3.connect(db_path, timeout=5); cur = conn.cursor()
        def has(t):
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", (t,)); return cur.fetchone() is not None
        if has("swarm_sessions"):
            cur.execute("INSERT OR IGNORE INTO swarm_sessions (id, team_name, session_id, project, status, started_at, notes) VALUES (?, ?, ?, ?, 'running', ?, ?)",
                        (team_id, team_id, session_id, project, iso_ts, NOTES))
        # Native TeammateIdle payloads carry empty agent_id/agent_type (verified 2026-07-03,
        # 97/97 events); teammate_name is always populated — keyed by session+name instead.
        # worktree/tokens are unavailable at this hook event.
        if has("teammate_runs") and teammate and team_id:
            row_id = f"{team_id}-{teammate}"
            cur.execute("INSERT INTO teammate_runs (id, swarm_id, agent_role, agent_def, status, started_at, ended_at) VALUES (?, ?, ?, ?, 'idle', ?, ?) ON CONFLICT(id) DO UPDATE SET ended_at=excluded.ended_at, status='idle'",
                        (row_id, team_id, teammate, agent_type, iso_ts, iso_ts))
        conn.commit(); conn.close()
    except Exception: pass
PYEOF

exit 0
