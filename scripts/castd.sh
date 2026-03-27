#!/bin/bash
# castd.sh — CAST Daemon: persistent task queue processor
#
# Usage: castd.sh [--once]
#   --once   Process one pending task and exit (useful for testing)
#
# Reads:  ~/.claude/cast.db (task_queue table)
# Writes: ~/.claude/logs/castd.log
#         ~/.claude/run/castd.pid
#
# Escape hatches (none — this script is a daemon, not a git hook)
#
# Scheduled tasks seeded on startup:
#   07:00 daily  → morning-briefing
#   18:00 daily  → chain-reporter (daily summary)
#   09:00 Monday → report-writer (weekly cost report)

# ── Subprocess guard (prevent recursive dispatch) ────────────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
CAST_DB="${HOME}/.claude/cast.db"
LOG_FILE="${HOME}/.claude/logs/castd.log"
PID_FILE="${HOME}/.claude/run/castd.pid"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${HOME}/.claude/agents"

POLL_INTERVAL=30          # seconds between task_queue polls
STALE_LEASE_MINUTES=30    # minutes before a claimed task is considered crashed
CONNECTIVITY_RECHECK=5    # re-check network every N poll cycles

# ── Parse args ────────────────────────────────────────────────────────────────
RUN_ONCE=0
if [[ "${1:-}" == "--once" ]]; then
  RUN_ONCE=1
fi

# ── Logging helper ───────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
  # Also echo to stdout so systemd/launchd captures it
  echo "${ts} [${level}] ${msg}"
}

# ── PID file management ──────────────────────────────────────────────────────
write_pid() {
  echo "$$" > "$PID_FILE"
}

remove_pid() {
  rm -f "$PID_FILE"
}

# ── SIGTERM handler: finish current task then exit cleanly ───────────────────
SHUTDOWN_REQUESTED=0
trap 'SHUTDOWN_REQUESTED=1; log INFO "SIGTERM received — will exit after current task"' SIGTERM SIGINT

# ── Connectivity check ───────────────────────────────────────────────────────
CAST_OFFLINE=0
POLL_CYCLE=0

check_connectivity() {
  # Returns 0 if online, 1 if offline
  if curl -sf --max-time 3 https://api.anthropic.com > /dev/null 2>&1; then
    return 0
  fi
  return 1
}

update_connectivity() {
  if check_connectivity; then
    if [[ "$CAST_OFFLINE" -eq 1 ]]; then
      log INFO "Connectivity restored — CAST_OFFLINE cleared"
    fi
    CAST_OFFLINE=0
  else
    CAST_OFFLINE=1; log WARN "[CAST-OFFLINE] No network — cloud tasks will be deferred"
  fi
}

# ── Crash recovery: reset stale claimed tasks back to pending ────────────────
recover_stale_tasks() {
  if [[ ! -f "$CAST_DB" ]]; then return; fi

  local recovered
  recovered=$(sqlite3 "$CAST_DB" "
    UPDATE task_queue
    SET    status = 'pending',
           claimed_at = NULL,
           claimed_by_session = NULL,
           retry_count = retry_count + 1
    WHERE  status = 'claimed'
      AND  claimed_at < datetime('now', '-${STALE_LEASE_MINUTES} minutes')
      AND  retry_count < max_retries;
    SELECT changes();
  " 2>/dev/null || echo "0")

  if [[ "${recovered:-0}" -gt 0 ]]; then
    log WARN "Crash recovery: reset ${recovered} stale claimed task(s) to pending"
  fi
}

# ── Scheduled task seeding ───────────────────────────────────────────────────
seed_scheduled_tasks() {
  if [[ ! -f "$CAST_DB" ]]; then return; fi

  # Compute next occurrence times using Python (handles local timezone correctly)
  python3 - "$CAST_DB" <<'PYEOF' 2>/dev/null || true
import sys, sqlite3
from datetime import datetime, timedelta, timezone
import subprocess, os

db_path = sys.argv[1]

def local_now():
    return datetime.now()

def next_daily_at(hour, minute=0):
    """Return next datetime at the given local hour:minute (today or tomorrow)."""
    now = local_now()
    candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if candidate <= now:
        candidate += timedelta(days=1)
    return candidate

def next_monday_at(hour, minute=0):
    """Return next Monday at the given local hour:minute."""
    now = local_now()
    days_ahead = 0 - now.weekday()  # Monday is 0
    if days_ahead <= 0:
        days_ahead += 7
    candidate = (now + timedelta(days=days_ahead)).replace(
        hour=hour, minute=minute, second=0, microsecond=0)
    if candidate <= now:
        candidate += timedelta(days=7)
    return candidate

def iso(dt):
    return dt.strftime('%Y-%m-%dT%H:%M:%S')

SCHEDULED = [
    {
        'agent':  'morning-briefing',
        'task':   'Generate morning briefing: summarize pending tasks, recent agent activity, and priorities for today',
        'priority': 3,
        'scheduled_for': iso(next_daily_at(7, 0)),
    },
    {
        'agent':  'chain-reporter',
        'task':   'Generate daily summary: summarize all agent_runs completed today from cast.db, highlight any BLOCKED or DONE_WITH_CONCERNS statuses',
        'priority': 5,
        'scheduled_for': iso(next_daily_at(18, 0)),
    },
    {
        'agent':  'report-writer',
        'task':   'Generate weekly cost report from cast.db agent_runs: show total cost_usd by model, local vs cloud split, cost savings this week',
        'priority': 5,
        'scheduled_for': iso(next_monday_at(9, 0)),
    },
]

try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()

    for item in SCHEDULED:
        # Avoid duplicates: skip if same agent + scheduled_for already pending or claimed
        existing = cur.execute("""
            SELECT COUNT(*) FROM task_queue
            WHERE agent = ?
              AND scheduled_for = ?
              AND status IN ('pending', 'claimed')
        """, (item['agent'], item['scheduled_for'])).fetchone()[0]

        if existing == 0:
            cur.execute("""
                INSERT INTO task_queue
                  (created_at, project, project_root, agent, task, priority,
                   status, scheduled_for)
                VALUES
                  (datetime('now'), 'cast-system', NULL, ?, ?, ?,
                   'pending', ?)
            """, (item['agent'], item['task'], item['priority'], item['scheduled_for']))
            print(f"Seeded: {item['agent']} at {item['scheduled_for']}")

    con.commit()
    con.close()
except Exception as e:
    print(f"Warning: seed_scheduled_tasks failed — {e}", file=sys.stderr)
PYEOF

  log INFO "Scheduled task seeding complete"
}

# Re-seed the next occurrence of a scheduled task after it completes
reseed_next_occurrence() {
  local agent="$1"
  local prev_scheduled="$2"

  python3 - "$CAST_DB" "$agent" "$prev_scheduled" <<'PYEOF' 2>/dev/null || true
import sys, sqlite3
from datetime import datetime, timedelta

db_path       = sys.argv[1]
agent         = sys.argv[2]
prev_sched    = sys.argv[3]

DAILY_AGENTS = {
    'morning-briefing': {
        'hour': 7, 'minute': 0,
        'task': 'Generate morning briefing: summarize pending tasks, recent agent activity, and priorities for today',
        'priority': 3,
    },
    'chain-reporter': {
        'hour': 18, 'minute': 0,
        'task': 'Generate daily summary: summarize all agent_runs completed today from cast.db, highlight any BLOCKED or DONE_WITH_CONCERNS statuses',
        'priority': 5,
    },
}
WEEKLY_AGENTS = {
    'report-writer': {
        'weekday': 0, 'hour': 9, 'minute': 0,
        'task': 'Generate weekly cost report from cast.db agent_runs: show total cost_usd by model, local vs cloud split, cost savings this week',
        'priority': 5,
    },
}

def iso(dt):
    return dt.strftime('%Y-%m-%dT%H:%M:%S')

try:
    prev = datetime.fromisoformat(prev_sched)
except Exception:
    prev = datetime.now()

next_dt = None
task_text = None
priority = 5

if agent in DAILY_AGENTS:
    cfg = DAILY_AGENTS[agent]
    next_dt = (prev + timedelta(days=1)).replace(
        hour=cfg['hour'], minute=cfg['minute'], second=0, microsecond=0)
    task_text = cfg['task']
    priority  = cfg['priority']
elif agent in WEEKLY_AGENTS:
    cfg = WEEKLY_AGENTS[agent]
    next_dt = (prev + timedelta(days=7)).replace(
        hour=cfg['hour'], minute=cfg['minute'], second=0, microsecond=0)
    task_text = cfg['task']
    priority  = cfg['priority']

if next_dt is None:
    sys.exit(0)

try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()

    existing = cur.execute("""
        SELECT COUNT(*) FROM task_queue
        WHERE agent = ? AND scheduled_for = ? AND status IN ('pending', 'claimed')
    """, (agent, iso(next_dt))).fetchone()[0]

    if existing == 0:
        cur.execute("""
            INSERT INTO task_queue
              (created_at, project, project_root, agent, task, priority, status, scheduled_for)
            VALUES
              (datetime('now'), 'cast-system', NULL, ?, ?, ?, 'pending', ?)
        """, (agent, task_text, priority, iso(next_dt)))
        con.commit()
        print(f"Re-seeded: {agent} at {iso(next_dt)}")

    con.close()
except Exception as e:
    print(f"Warning: reseed failed — {e}", file=sys.stderr)
PYEOF
}

# ── macOS notification ────────────────────────────────────────────────────────
notify() {
  local title="$1"
  local body="$2"
  # Graceful — notification failure never stops the daemon
  osascript -e "display notification \"${body}\" with title \"${title}\"" 2>/dev/null || true
}

# ── Claim and execute one pending task ───────────────────────────────────────
process_one_task() {
  if [[ ! -f "$CAST_DB" ]]; then
    log WARN "cast.db not found at ${CAST_DB} — skipping poll"
    return 0
  fi

  # Fetch one eligible pending task (priority ASC = highest priority first)
  # Use a temp file for the Python script — bash 3.2 (macOS default) does not
  # reliably handle heredocs containing parentheses inside $() subshells.
  local task_json
  local _py_fetch
  _py_fetch=$(mktemp /tmp/castd-fetch.XXXXXX.py)
  cat > "$_py_fetch" << 'PYEOF'
import sys, sqlite3, json

db_path     = sys.argv[1]

try:
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    row = cur.execute("""
        SELECT id, agent, task, priority, project, project_root,
               scheduled_for, retry_count, max_retries
        FROM   task_queue
        WHERE  status = 'pending'
          AND  (scheduled_for IS NULL OR scheduled_for <= datetime('now'))
        ORDER BY priority ASC, created_at ASC
        LIMIT 1
    """).fetchone()

    if row is None:
        print("")
    else:
        print(json.dumps(dict(row)))

    con.close()
except Exception as e:
    print("", file=sys.stderr)
PYEOF
  task_json=$(python3 "$_py_fetch" "$CAST_DB" 2>/dev/null || echo "")
  rm -f "$_py_fetch"

  if [[ -z "$task_json" ]]; then
    return 0  # Nothing to do
  fi

  # Parse task fields
  local task_id agent task_text project project_root scheduled_for retry_count max_retries
  task_id=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
  agent=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['agent'])" 2>/dev/null || echo "")
  task_text=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['task'])" 2>/dev/null || echo "")
  project=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project') or '')" 2>/dev/null || echo "")
  project_root=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project_root') or '')" 2>/dev/null || echo "")
  scheduled_for=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scheduled_for') or '')" 2>/dev/null || echo "")
  retry_count=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('retry_count', 0))" 2>/dev/null || echo "0")
  max_retries=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('max_retries', 3))" 2>/dev/null || echo "3")

  if [[ -z "$task_id" || -z "$agent" ]]; then
    log WARN "Malformed task row — skipping"
    return 0
  fi

  # Claim the task atomically
  local claim_result
  claim_result=$(python3 - "$CAST_DB" "$task_id" <<'PYEOF'
import sqlite3, sys, os
db_path, task_id = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db_path)
cur = conn.execute(
    "UPDATE task_queue SET status='claimed', claimed_at=datetime('now'), claimed_by_session=? WHERE id=? AND status='pending'",
    (f'castd-{os.getpid()}', task_id)
)
conn.commit()
print(cur.rowcount)
conn.close()
PYEOF
)

  if [[ "${claim_result:-0}" -eq 0 ]]; then
    # Another process claimed it first — skip
    log DEBUG "Task ${task_id} already claimed by another process — skipping"
    return 0
  fi

  log INFO "Claimed task ${task_id}: agent=${agent} retry=${retry_count}/${max_retries}"

  # Offline check: defer tasks if offline
  if [[ "$CAST_OFFLINE" -eq 1 ]]; then
    log WARN "Task ${task_id} deferred — CAST_OFFLINE=1, resetting to pending"
    python3 - "$CAST_DB" "$task_id" <<'PYEOF'
import sqlite3, sys
db_path, task_id = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db_path)
conn.execute("UPDATE task_queue SET status='pending', claimed_at=NULL, claimed_by_session=NULL WHERE id=?", (task_id,))
conn.commit()
conn.close()
PYEOF
    return 0
  fi

  log INFO "Executing task ${task_id}: agent=${agent}"
  local output exit_code
  exit_code=0

  # Set working directory to project root if available
  local run_dir="${HOME}"
  if [[ -n "$project_root" && -d "$project_root" ]]; then
    run_dir="$project_root"
  fi

  # Task execution via Claude API (cloud only)
  output="" ; exit_code=0

  # Determine status from output
  local run_status="done"
  if echo "$output" | grep -qE '^Status:[[:space:]]*(BLOCKED|NEEDS_CONTEXT)'; then
    run_status="failed"
  elif [[ $exit_code -ne 0 ]]; then
    run_status="failed"
  fi

  local result_summary
  result_summary=$(echo "$output" | head -c 200)

  if [[ "$run_status" == "done" ]]; then
    python3 - "$CAST_DB" "$task_id" "$result_summary" <<'PYEOF'
import sqlite3, sys
db_path, task_id, result_summary = sys.argv[1], int(sys.argv[2]), sys.argv[3][:200]
conn = sqlite3.connect(db_path)
conn.execute("UPDATE task_queue SET status='done', completed_at=datetime('now'), result_summary=? WHERE id=?", (result_summary, task_id))
conn.commit()
conn.close()
PYEOF

    log INFO "Task ${task_id} DONE: ${agent}"
    notify "CAST Task Done" "Agent ${agent} completed task ${task_id}"

    # Re-seed next occurrence for scheduled tasks
    if [[ -n "$scheduled_for" ]]; then
      reseed_next_occurrence "$agent" "$scheduled_for"
    fi

  else
    # Failed — check retry eligibility
    if [[ "$retry_count" -lt "$max_retries" ]]; then
      python3 - "$CAST_DB" "$task_id" <<'PYEOF'
import sqlite3, sys
db_path, task_id = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db_path)
conn.execute("UPDATE task_queue SET status='pending', claimed_at=NULL, claimed_by_session=NULL, retry_count=retry_count+1 WHERE id=?", (task_id,))
conn.commit()
conn.close()
PYEOF
      log WARN "Task ${task_id} FAILED (retry $((retry_count+1))/${max_retries}): ${agent}"
    else
      python3 - "$CAST_DB" "$task_id" "$result_summary" <<'PYEOF'
import sqlite3, sys
db_path, task_id, result_summary = sys.argv[1], int(sys.argv[2]), sys.argv[3][:200]
conn = sqlite3.connect(db_path)
conn.execute("UPDATE task_queue SET status='failed', completed_at=datetime('now'), result_summary=? WHERE id=?", (result_summary, task_id))
conn.commit()
conn.close()
PYEOF
      log ERROR "Task ${task_id} FAILED permanently after ${max_retries} retries: ${agent}"
      notify "CAST Task Failed" "Agent ${agent} task ${task_id} failed permanently"
    fi
  fi

  return 0
}

# ── Main loop ────────────────────────────────────────────────────────────────
main() {
  log INFO "castd starting (PID=$$)"
  write_pid

  # Initial connectivity check
  update_connectivity

  # Crash recovery on startup
  recover_stale_tasks

  # Seed scheduled intelligence tasks
  seed_scheduled_tasks

  if [[ "$RUN_ONCE" -eq 1 ]]; then
    process_one_task
    remove_pid
    log INFO "castd --once complete, exiting"
    exit 0
  fi

  while true; do
    if [[ "$SHUTDOWN_REQUESTED" -eq 1 ]]; then
      log INFO "Shutdown requested — castd exiting cleanly"
      remove_pid
      exit 0
    fi

    # Re-check connectivity every CONNECTIVITY_RECHECK cycles
    POLL_CYCLE=$(( POLL_CYCLE + 1 ))
    if (( POLL_CYCLE % CONNECTIVITY_RECHECK == 0 )); then
      update_connectivity
    fi

    process_one_task || true

    # Sleep in short intervals to remain responsive to SIGTERM
    local slept=0
    while [[ $slept -lt $POLL_INTERVAL ]]; do
      if [[ "$SHUTDOWN_REQUESTED" -eq 1 ]]; then break; fi
      sleep 2
      slept=$(( slept + 2 ))
    done
  done
}

main "$@"
