#!/usr/bin/env bash
# cast-duration-check.sh — SubagentStop advisory hook (called from cast-subagent-worktree-check.sh)
#
# Reads duration_ms directly from agent_runs.duration_ms for the current run.
# Computes p95 over the rolling 30-day window (agent_type, at least 5 samples).
# If current run exceeds p95, inserts a slow_agent event into routing_events
# and emits [CAST-PERF] banner to stderr.
# Always exits 0.

[[ "${CLAUDE_SUBPROCESS:-}" == "1" ]] && exit 0

set -euo pipefail

INPUT="${CAST_INPUT:-$(cat 2>/dev/null || true)}"

_log_error() {
  mkdir -p "$HOME/.claude/logs"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cast-duration-check: $1" \
    >> "$HOME/.claude/logs/hook-errors.log"
}

DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"

python3 - "$DB_PATH" <<'PYEOF' || _log_error "duration check failed"
import json
import os
import sqlite3
import sys
from datetime import datetime

db_path = sys.argv[1]

# Parse SubagentStop JSON from env (passed by worktree-check.sh as CAST_INPUT)
raw = os.environ.get("CAST_INPUT", "")
try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    payload = {}

agent_type = (
    payload.get("agent_type") or
    payload.get("subagent_type") or
    payload.get("matched_route") or
    "unknown"
)
agent_id = payload.get("agent_id") or payload.get("subagent_id") or ""
session_id = os.environ.get("CLAUDE_SESSION_ID", "unknown")
now_iso = datetime.utcnow().isoformat() + 'Z'

try:
    conn = sqlite3.connect(db_path, timeout=5)
except Exception as e:
    print(f"[cast-duration-check] DB open failed: {e}", file=sys.stderr)
    sys.exit(0)

# Look up duration_ms directly from agent_runs — prefer agent_id match, fall back to most-recent for session
duration_ms = None
try:
    if agent_id:
        row = conn.execute(
            "SELECT duration_ms FROM agent_runs WHERE agent_id = ? AND duration_ms IS NOT NULL ORDER BY id DESC LIMIT 1",
            (agent_id,)
        ).fetchone()
        if row:
            duration_ms = row[0]
    if duration_ms is None and session_id and session_id != "unknown":
        row = conn.execute(
            "SELECT duration_ms FROM agent_runs WHERE session_id = ? AND duration_ms IS NOT NULL ORDER BY id DESC LIMIT 1",
            (session_id,)
        ).fetchone()
        if row:
            duration_ms = row[0]
except Exception as e:
    print(f"[cast-duration-check] duration_ms lookup failed: {e}", file=sys.stderr)
    conn.close()
    sys.exit(0)

if duration_ms is None:
    # No duration data — nothing to compare
    conn.close()
    sys.exit(0)

# Query historical duration_ms for this agent_type over rolling 30 days
try:
    rows = conn.execute(
        "SELECT duration_ms FROM agent_runs "
        "WHERE agent = ? AND duration_ms IS NOT NULL "
        "AND started_at >= datetime('now','-30 days') "
        "ORDER BY duration_ms",
        (agent_type,)
    ).fetchall()
except Exception as e:
    print(f"[cast-duration-check] p95 query failed: {e}", file=sys.stderr)
    conn.close()
    sys.exit(0)

samples = [r[0] for r in rows if r[0] is not None]
sample_count = len(samples)

if sample_count < 5:
    # Not enough historical data for a meaningful p95
    conn.close()
    sys.exit(0)

# Compute p95
p95_index = int(0.95 * sample_count) - 1
p95_index = max(0, min(p95_index, sample_count - 1))
p95_ms = samples[p95_index]

if duration_ms <= p95_ms:
    conn.close()
    sys.exit(0)

# Insert slow_agent event into routing_events (existing table)
data_json = json.dumps({
    "duration_ms": duration_ms,
    "p95_ms": p95_ms,
    "agent_type": agent_type,
    "sample_count": sample_count
})
try:
    conn.execute(
        "INSERT INTO routing_events (session_id, timestamp, event_type, matched_route, data) "
        "VALUES (?, ?, ?, ?, ?)",
        (session_id, now_iso, "slow_agent", agent_type, data_json)
    )
    conn.commit()
except Exception as e:
    print(f"[cast-duration-check] routing_events insert failed: {e}", file=sys.stderr)

conn.close()

print(
    f"[CAST-PERF] {agent_type} exceeded p95 duration ({duration_ms}ms vs p95 {p95_ms}ms, "
    f"n={sample_count} samples)",
    file=sys.stderr
)
PYEOF

exit 0
