#!/bin/bash
# cast-ci-monitor.sh — CAST CI Failure Monitor
#
# Polls GitHub Actions for failed runs on the main branch of
# ek33450505/claude-agent-team. When a new failure is detected (one not
# previously reported), it writes an event JSON to:
#   ~/.claude/cast/events/ci-failure-<timestamp>.json
# and fires a desktop notification via cast-notify.sh.
#
# State is persisted in ~/.claude/cast/ci-monitor-state.json to avoid
# duplicate alerts across runs.
#
# Usage:
#   cast-ci-monitor.sh              Run the check
#   cast-ci-monitor.sh --status     Print last-seen run IDs and exit
#   cast-ci-monitor.sh --reset      Clear state file and exit
#
# Requires: gh CLI (authenticated), python3
#
# Log output: ~/.claude/logs/cron-ci-monitor.log
#
# Called by cron — see cast-cron-setup.sh for scheduling.

# ── Subprocess guard ──────────────────────────────────────────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
STATE_FILE="${CAST_DIR}/ci-monitor-state.json"
LOGS_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOGS_DIR}/cron-ci-monitor.log"

REPO="ek33450505/claude-agent-team"
BRANCH="main"
CHECK_LIMIT=10   # How many recent runs to inspect per query

# ── Ensure directories exist ──────────────────────────────────────────────────
mkdir -p "$EVENTS_DIR" "$LOGS_DIR"

# ── Argument dispatch ─────────────────────────────────────────────────────────
case "${1:-}" in
  --status)
    if [ -f "$STATE_FILE" ]; then
      echo "CI monitor state:"
      python3 -c "
import json, sys
with open('${STATE_FILE}') as f:
    s = json.load(f)
seen = s.get('seen_run_ids', [])
last = s.get('last_check_ts', 'never')
print(f'  Last check:     {last}')
print(f'  Seen run IDs:   {len(seen)} total')
if seen:
    print(f'  Most recent:    {seen[-1]}')
"
    else
      echo "No state file found at ${STATE_FILE}"
    fi
    exit 0
    ;;
  --reset)
    rm -f "$STATE_FILE"
    echo "CI monitor state cleared."
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Usage: cast-ci-monitor.sh [--status|--reset]" >&2
    exit 1
    ;;
esac

# ── Log helper ────────────────────────────────────────────────────────────────
log() {
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "[${ts}] $*" >> "$LOG_FILE"
}

log "cast-ci-monitor: starting check for ${REPO} branch=${BRANCH}"

# ── Verify gh is available ────────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  log "ERROR: gh CLI not found — cannot poll GitHub Actions"
  exit 0   # Exit cleanly so cron doesn't spam errors
fi

# ── Fetch recent workflow runs ────────────────────────────────────────────────
RAW_JSON=""
if ! RAW_JSON="$(gh run list \
    --repo "$REPO" \
    --branch "$BRANCH" \
    --limit "$CHECK_LIMIT" \
    --json "databaseId,status,conclusion,name,url,createdAt,headSha,workflowName" \
    2>&1)"; then
  log "ERROR: gh run list failed: ${RAW_JSON}"
  exit 0
fi

if [ -z "$RAW_JSON" ] || [ "$RAW_JSON" = "[]" ]; then
  log "No runs found or empty response — skipping"
  exit 0
fi

# ── Load previous state ───────────────────────────────────────────────────────
SEEN_IDS_JSON="[]"
if [ -f "$STATE_FILE" ]; then
  SEEN_IDS_JSON="$(python3 -c "
import json
try:
    s = json.load(open('${STATE_FILE}'))
    print(json.dumps(s.get('seen_run_ids', [])))
except Exception:
    print('[]')
" 2>/dev/null || echo "[]")"
fi

# ── Detect new failures and emit events ───────────────────────────────────────
# Delegate all logic to Python to keep shell quoting simple and safe.
NEW_FAILURES="$(python3 - "$RAW_JSON" "$SEEN_IDS_JSON" "$EVENTS_DIR" "$STATE_FILE" "$REPO" "$BRANCH" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

raw_json_str, seen_ids_json, events_dir, state_file, repo, branch = sys.argv[1:]

try:
    runs = json.loads(raw_json_str)
except json.JSONDecodeError as e:
    print(f"JSON parse error: {e}", file=sys.stderr)
    sys.exit(0)

try:
    seen_ids = set(json.loads(seen_ids_json))
except Exception:
    seen_ids = set()

# Identify runs that: completed, conclusion=failure/cancelled, not yet seen
new_failures = []
for run in runs:
    run_id = str(run.get("databaseId", ""))
    status = run.get("status", "")
    conclusion = run.get("conclusion", "")

    # Only completed runs with failure/cancelled conclusions
    if status != "completed":
        continue
    if conclusion not in ("failure", "cancelled", "timed_out"):
        continue
    if run_id in seen_ids:
        continue

    new_failures.append(run)
    seen_ids.add(run_id)

# Emit one event file per new failure
emitted = []
for run in new_failures:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    ts_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    event_file = os.path.join(events_dir, f"ci-failure-{ts}-{run.get('databaseId', 'unknown')}.json")

    event = {
        "event_id": f"ci-failure-{ts}",
        "timestamp": ts_iso,
        "event_type": "ci_failure",
        "agent": "cast-ci-monitor",
        "task_id": f"ci-failure-{run.get('databaseId', 'unknown')}",
        "summary": (
            f"CI FAILURE: {run.get('workflowName', run.get('name', 'unknown'))} "
            f"on {branch} — conclusion={run.get('conclusion')} — {run.get('url', '')}"
        ),
        "details": {
            "repo": repo,
            "branch": branch,
            "run_id": run.get("databaseId"),
            "workflow_name": run.get("workflowName", run.get("name")),
            "conclusion": run.get("conclusion"),
            "status": run.get("status"),
            "url": run.get("url"),
            "created_at": run.get("createdAt"),
            "head_sha": run.get("headSha"),
        }
    }

    with open(event_file, "w") as f:
        json.dump(event, f, indent=2)

    emitted.append({
        "file": event_file,
        "workflow": run.get("workflowName", run.get("name")),
        "conclusion": run.get("conclusion"),
        "url": run.get("url"),
        "run_id": str(run.get("databaseId", "")),
    })

# Persist updated state
all_ids_list = sorted(seen_ids)
# Keep only last 200 to prevent unbounded growth
if len(all_ids_list) > 200:
    all_ids_list = all_ids_list[-200:]

state = {
    "last_check_ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "repo": repo,
    "branch": branch,
    "seen_run_ids": all_ids_list,
}
with open(state_file, "w") as f:
    json.dump(state, f, indent=2)

# Print summary for shell to capture
print(json.dumps(emitted))
PYEOF
)"

# ── Parse Python output and fire notifications ────────────────────────────────
FAILURE_COUNT="$(python3 -c "
import json, sys
try:
    items = json.loads('''${NEW_FAILURES}''')
    print(len(items))
except Exception:
    print(0)
" 2>/dev/null || echo "0")"

if [ "$FAILURE_COUNT" -eq 0 ]; then
  log "No new failures detected"
  exit 0
fi

log "Detected ${FAILURE_COUNT} new CI failure(s)"

# Fire desktop notification via cast-notify.sh
NOTIFY_SCRIPT="${SCRIPT_DIR}/cast-notify.sh"
if [ -x "$NOTIFY_SCRIPT" ]; then
  FAILURE_MSG="$(python3 -c "
import json
items = json.loads('''${NEW_FAILURES}''')
names = [i.get('workflow','?') for i in items]
print(', '.join(names[:3]) + (' ...' if len(names) > 3 else ''))
" 2>/dev/null || echo "CI failure on ${REPO}")"

  bash "$NOTIFY_SCRIPT" "ci_failure" \
    "${FAILURE_COUNT} new CI failure(s) on ${BRANCH}: ${FAILURE_MSG}" \
    "CAST CI Monitor" 2>/dev/null || true
fi

# Log each failure for the record
python3 -c "
import json, sys
items = json.loads('''${NEW_FAILURES}''')
for item in items:
    print(f'  FAILED: {item.get(\"workflow\",\"?\")} — {item.get(\"conclusion\",\"?\")} — {item.get(\"url\",\"?\")}')
" 2>/dev/null | while IFS= read -r line; do log "$line"; done || true

log "cast-ci-monitor: done — wrote ${FAILURE_COUNT} event(s)"
exit 0
