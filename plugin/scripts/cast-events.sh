#!/bin/bash
# cast-events.sh — CAST Event-Sourcing Protocol
# Source this file to get: cast_emit_event, cast_write_review, cast_derive_state, cast_read_board
#
# Architecture: agents never share mutable state.
# Each agent writes its own immutable event file.
# State is derived from events by the orchestrator.
# Reviews are attached to specific artifact IDs, not global task state.
#
# Usage:
#   source ~/.claude/scripts/cast-events.sh
#   cast_emit_event "task_claimed"  "orchestrator" "batch-1" "" "Starting architecture review"
#   cast_write_review "batch-1-plan" "code-reviewer" "approved" "Looks good" ""
#   cast_derive_state "batch-1"
#   cast_read_board
#
# Directory layout (all under ~/.claude/cast/):
#   events/    — append-only, one JSON file per agent action: {timestamp}-{agent}-{task_id}.json
#   state/     — derived task state written by orchestrator: {task_id}.json
#   reviews/   — review decisions attached to artifacts: {artifact_id}-{reviewer}-{timestamp}.json
#   artifacts/ — plans, patches, test files: {task_id}-{type}-{timestamp}.{ext}

CAST_DIR="${HOME}/.claude/cast"
CAST_EVENTS_DIR="${CAST_DIR}/events"
CAST_STATE_DIR="${CAST_DIR}/state"
CAST_REVIEWS_DIR="${CAST_DIR}/reviews"
CAST_ARTIFACTS_DIR="${CAST_DIR}/artifacts"

# --- API key resolution (priority: env var override > Keychain > unset) ---
# Keychain is the PRIMARY source on macOS. The env var acts as an override:
# if ANTHROPIC_API_KEY is already set in the environment, it wins and we skip
# the Keychain lookup entirely. If neither is available, we continue without it.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
  _keychain_key=$(security find-generic-password -s cast-anthropic-api-key -a cast -w 2>/dev/null || true)
  if [[ -n "$_keychain_key" ]]; then
    export ANTHROPIC_API_KEY="$_keychain_key"
  fi
  unset _keychain_key
fi

# --- Connectivity check utility ---
# Calls cast-connectivity.sh check if available. Returns 0=online, 1=offline.
cast_check_connectivity() {
  local script="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}/cast-connectivity.sh"
  if [[ -x "$script" ]]; then
    "$script" check >/dev/null 2>&1
    return $?
  else
    # Fallback: direct ping check
    ping -c 1 -W 2 api.anthropic.com >/dev/null 2>&1
    return $?
  fi
}

_cast_init_dirs() {
  mkdir -p "$CAST_EVENTS_DIR" "$CAST_STATE_DIR" "$CAST_REVIEWS_DIR" "$CAST_ARTIFACTS_DIR"
}

# Append an immutable event file.
# Usage: cast_emit_event <event_type> <agent> <task_id> [artifact_id] [summary] [status] [concerns]
# event_type: task_created | task_claimed | task_completed | task_blocked | task_rejected | artifact_written | review_submitted
# status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT | IN_PROGRESS | (empty)
cast_emit_event() {
  local event_type="$1"
  local agent="$2"
  local task_id="$3"
  local artifact_id="${4:-}"
  local summary="${5:-}"
  local run_status="${6:-}"
  local concerns="${7:-}"

  _cast_init_dirs

  local ts
  ts="${CAST_EVENT_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"  # test seam: inject for deterministic filename ordering
  local ts_iso
  ts_iso="${CAST_EVENT_TS_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"  # test seam: inject ISO timestamp
  local safe_task_id="${task_id//\//-}"
  local event_file="${CAST_EVENTS_DIR}/${ts}-${agent}-${safe_task_id}.json"

  python3 - "$event_type" "$agent" "$task_id" "$artifact_id" "$summary" "$run_status" "$concerns" "$ts" "$event_file" "$ts_iso" <<'PYEOF'
import json, sys
event_type, agent, task_id, artifact_id, summary, status, concerns, ts, filepath, ts_iso = sys.argv[1:]
event = {
    "event_id": f"{ts}-{agent}-{task_id}",
    "timestamp": ts_iso,
    "agent": agent,
    "task_id": task_id,
    "parent_task_id": None,
    "event_type": event_type,
    "status": status if status else None,
    "summary": summary if summary else None,
    "artifact_id": artifact_id if artifact_id else None,
    "concerns": concerns if concerns else None
}
with open(filepath, 'w') as f:
    json.dump(event, f, indent=2)
print(filepath, file=__import__('sys').stderr)
PYEOF

  # Mirror to routing-log.jsonl for dashboard visibility
  # Only for actionable event types; skip artifact/review noise
  if [[ "$event_type" == "task_claimed" || "$event_type" == "task_completed" || "$event_type" == "task_blocked" ]]; then
    CAST_ETYPE="$event_type" CAST_AGENT="$agent" CAST_TASK="$task_id" \
    CAST_SUMMARY="$summary" CAST_STATUS="$run_status" CAST_TS="$ts_iso" \
    python3 -c "
import json, os
etype   = os.environ.get('CAST_ETYPE', '')
agent   = os.environ.get('CAST_AGENT', '')
task_id = os.environ.get('CAST_TASK', '')
summary = os.environ.get('CAST_SUMMARY', '')
status  = os.environ.get('CAST_STATUS', '')
ts      = os.environ.get('CAST_TS', '')
action  = 'agent_dispatch' if etype == 'task_claimed' else ('agent_complete' if etype == 'task_completed' else 'agent_blocked')
entry = {
    'timestamp':      ts,
    'event_type':     etype,
    'action':         action,
    'matched_route':  agent,
    'agent_name':     agent,
    'prompt_preview': summary[:80] if summary else task_id,
    'command':        None,
    'status':         status if status else None,
    'task_id':        task_id,
}
import subprocess
subprocess.run(
    ['python3', os.path.join(os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts')), 'cast-db-log.py')],
    input=json.dumps(entry), text=True, timeout=5
)
" 2>/dev/null || true
  fi
}

# Write a review decision attached to a specific artifact.
# Usage: cast_write_review <artifact_id> <reviewer> <decision> <feedback> [recommended_agents]
# decision: approved | rejected
cast_write_review() {
  local artifact_id="$1"
  local reviewer="$2"
  local decision="$3"
  local feedback="${4:-}"
  local recommended="${5:-}"

  _cast_init_dirs

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local ts_iso
  ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Safe filename: replace slashes in artifact_id
  local safe_artifact
  safe_artifact="${artifact_id//\//-}"
  local review_file="${CAST_REVIEWS_DIR}/${safe_artifact}-${reviewer}-${ts}.json"

  python3 - "$artifact_id" "$reviewer" "$decision" "$feedback" "$recommended" "$ts" "$review_file" "$ts_iso" <<'PYEOF'
import json, sys
artifact_id, reviewer, decision, feedback, recommended, ts, filepath, ts_iso = sys.argv[1:]
review = {
    "review_id": f"{artifact_id}-{reviewer}-{ts}",
    "artifact_id": artifact_id,
    "reviewer": reviewer,
    "decision": decision,
    "timestamp": ts_iso,
    "feedback": feedback if feedback else None,
    "recommended_agents": [a.strip() for a in recommended.split(",") if a.strip()] if recommended else []
}
with open(filepath, 'w') as f:
    json.dump(review, f, indent=2)
PYEOF

  # Also emit a review_submitted event to the event log
  cast_emit_event "review_submitted" "$reviewer" "$artifact_id" "$artifact_id" "$decision: $feedback" "$decision" ""
}

# Derive and write current state for a task_id by replaying its events.
# Writes ~/.claude/cast/state/{task_id}.json
# Usage: cast_derive_state <task_id>
cast_derive_state() {
  local task_id="$1"
  _cast_init_dirs

  local safe_task="${task_id//\//-}"
  local state_file="${CAST_STATE_DIR}/${safe_task}.json"

  python3 - "$CAST_EVENTS_DIR" "$CAST_REVIEWS_DIR" "$task_id" "$state_file" <<'PYEOF'
import json, sys, os, glob

events_dir, reviews_dir, task_id, state_file = sys.argv[1:]

# Replay events for this task in timestamp order
pattern = os.path.join(events_dir, f"*-*-{task_id}.json")
event_files = sorted(glob.glob(pattern))

state = {
    "task_id": task_id,
    "status": "pending",
    "owner": None,
    "artifact_ids": [],
    "last_event": None,
    "last_updated": None,
    "summary": None
}

for ef in event_files:
    try:
        with open(ef) as f:
            ev = json.load(f)
    except Exception:
        continue
    if ev.get("task_id") != task_id:
        continue
    et = ev.get("event_type", "")
    if et == "task_claimed":
        state["owner"] = ev.get("agent")
        state["status"] = "in_progress"
    elif et in ("task_completed",):
        state["status"] = ev.get("status") or "DONE"
    elif et == "task_blocked":
        state["status"] = "BLOCKED"
    elif et == "artifact_written" and ev.get("artifact_id"):
        if ev["artifact_id"] not in state["artifact_ids"]:
            state["artifact_ids"].append(ev["artifact_id"])
    state["last_event"] = et
    state["last_updated"] = ev.get("timestamp")
    state["summary"] = ev.get("summary") or state["summary"]

# Collect reviews for all artifacts
approvals = []
rejections = []
for aid in state["artifact_ids"]:
    safe_aid = aid.replace("/", "-")
    rfiles = sorted(glob.glob(os.path.join(reviews_dir, f"{safe_aid}-*.json")))
    for rf in rfiles:
        try:
            with open(rf) as f:
                rv = json.load(f)
            if rv.get("decision") == "approved":
                approvals.append(rv.get("reviewer"))
            elif rv.get("decision") == "rejected":
                rejections.append(rv.get("reviewer"))
        except Exception:
            continue

state["approvals"] = list(set(approvals))
state["rejections"] = list(set(rejections) - set(approvals))  # net rejections

with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

# Check if a task_id has all required approvals (for commit gating).
# Usage: cast_check_approvals <task_id> <required_reviewer1> [required_reviewer2 ...]
# Returns 0 if all required approvals present, 1 if missing, 2 if any unanswered rejections
#
# Two-tier resolution per required reviewer:
#   1. File-based state (cast_derive_state): a recorded approved/rejected decision keyed to
#      the task's artifact_ids. This is the DB-tracked /orchestrate path; tried first, unchanged.
#   2. Session-scoped agent_runs fallback (when the file path yields no approval): the
#      hook-populated agent_runs row for the most-recent same-session run of that reviewer,
#      within CAST_APPROVAL_WINDOW_MIN minutes (default 120), guarded by branch match. Covers
#      ad-hoc Agent-tool dispatches that never thread a TASK_ID or emit artifact_written events.
#      Fails CLOSED (missing) when no session id is resolvable. See docs/phase14-review-plumbing.md
#      (Root Cause 4).
cast_check_approvals() {
  local task_id="$1"
  shift
  local required=("$@")
  [ "${#required[@]}" -eq 0 ] && { echo "All required approvals present (none required)"; return 0; }

  cast_derive_state "$task_id" >/dev/null 2>&1

  local safe_task="${task_id//\//-}"
  local state_file="${CAST_STATE_DIR}/${safe_task}.json"

  # Session + branch context for the agent_runs fallback (best-effort; empty when unknown)
  local sid="${CAST_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  local cur_branch
  cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  local window_min="${CAST_APPROVAL_WINDOW_MIN:-120}"
  local db_path="${CAST_DB_PATH:-$HOME/.claude/cast.db}"

  python3 - "$state_file" "$sid" "$cur_branch" "$window_min" "$db_path" "${required[@]}" <<'PYEOF'
import json, os, sqlite3, sys
from datetime import datetime, timedelta, timezone

state_file = sys.argv[1]
session_id = sys.argv[2]
cur_branch = sys.argv[3]
try:
    window_min = int(sys.argv[4])
except (ValueError, IndexError):
    window_min = 120
window_min = min(max(window_min, 1), 1440)   # clamp: 1-min floor, 24h ceiling — an unbounded window lets a stale approval satisfy the gate
db_path = sys.argv[5]
required = sys.argv[6:]

# ── Tier 1: file-based decisions (DB-tracked /orchestrate path) ───────────────
approvals, rejections = set(), set()
try:
    with open(state_file) as f:
        state = json.load(f)
    approvals = set(state.get("approvals", []))
    rejections = set(state.get("rejections", []))
except Exception:
    pass  # no/unreadable state file → empty, fall through to the fallback

# A recorded rejection is authoritative — never overridden by the fallback.
if rejections:
    print(f"REJECTED by: {', '.join(sorted(rejections))}", file=sys.stderr)
    sys.exit(2)

missing = [r for r in required if r not in approvals]
if not missing:
    print("All required approvals present")
    sys.exit(0)

# ── Tier 2: session-scoped agent_runs fallback for still-missing reviewers ────
# Requires a session id to scope safely; without one we cannot tell this session's
# reviews from any other, so we fail CLOSED (missing), never open.
if not session_id:
    print(f"Missing approvals from: {', '.join(sorted(missing))}", file=sys.stderr)
    sys.exit(1)

def parse_ts(s):
    # Tolerant: accept 'T' or space separators, drop fractional/'Z' beyond 19 chars.
    s = (s or "").strip().replace("T", " ")[:19]
    try:
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None

cutoff = datetime.now(timezone.utc) - timedelta(minutes=window_min)
REJECT = {"BLOCKED"}  # decisive statuses selected in SQL; everything non-REJECT here = approve

still_missing, fallback_rejections = [], []
try:
    conn = sqlite3.connect(db_path, timeout=5)
    try:
        for r in missing:
            # Match the bare agent name OR its `<agent>__<label>` dispatch-naming
            # variant (working-conventions.md dispatch-naming rule) — LIKE '_' is a
            # single-char wildcard, so escape the literal pattern and anchor on a
            # literal "__" separator (never a bare "<agent>%" prefix, which would
            # also match an unrelated agent like "code-reviewer2").
            like_pattern = (
                r.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
                + '\\_\\_%'
            )
            row = conn.execute(
                "SELECT status, branch, ended_at FROM agent_runs "
                "WHERE session_id=? AND (agent=? OR agent LIKE ? ESCAPE '\\') "
                "AND ended_at IS NOT NULL AND ended_at != '' "
                "AND status IN ('DONE','DONE_WITH_CONCERNS','completed','BLOCKED') "
                "ORDER BY replace(ended_at, 'T', ' ') DESC LIMIT 1",
                (session_id, r, like_pattern),
            ).fetchone()
            if row is None:
                still_missing.append(r); continue
            status = (row[0] or "").strip()
            row_branch = (row[1] or "").strip()
            ts = parse_ts(row[2])
            # Freshness window (UTC-to-UTC; robust to timestamp-format variants).
            if ts is None or ts < cutoff:
                still_missing.append(r); continue
            # Branch guard: only when both branches are known and differ.
            if cur_branch and row_branch and row_branch != cur_branch:
                still_missing.append(r); continue
            if status in REJECT:
                fallback_rejections.append(r)
            # else: DONE / DONE_WITH_CONCERNS / completed → satisfied
    finally:
        conn.close()
except Exception as e:
    # DB unavailable/locked → fail CLOSED (do not spuriously approve).
    print(f"Missing approvals from: {', '.join(sorted(missing))} "
          f"(agent_runs fallback unavailable: {e})", file=sys.stderr)
    sys.exit(1)

if fallback_rejections:
    print(f"REJECTED by: {', '.join(sorted(set(fallback_rejections)))} (session agent_runs)",
          file=sys.stderr)
    sys.exit(2)
if still_missing:
    print(f"Missing approvals from: {', '.join(sorted(set(still_missing)))}", file=sys.stderr)
    sys.exit(1)
print(f"All required approvals present (session-scoped agent_runs fallback, window={window_min}m)")
sys.exit(0)
PYEOF
}

# Print a human-readable board of current state across all tasks.
cast_read_board() {
  _cast_init_dirs
  python3 - "$CAST_STATE_DIR" "$CAST_EVENTS_DIR" <<'PYEOF'
import json, sys, os, glob
from datetime import datetime

state_dir, events_dir = sys.argv[1:]

state_files = sorted(glob.glob(os.path.join(state_dir, "*.json")))
if not state_files:
    # Fallback: derive from events
    task_ids = set()
    for ef in glob.glob(os.path.join(events_dir, "*.json")):
        try:
            with open(ef) as f:
                ev = json.load(f)
            task_ids.add(ev.get("task_id", ""))
        except Exception:
            pass
    print(f"  No derived state yet. {len(task_ids)} task IDs seen in events/")
    sys.exit(0)

print(f"CAST Task Board — {len(state_files)} tasks")
print("═" * 60)
STATUS_ICON = {
    "DONE": "✓", "pending": "·", "in_progress": "⋯",
    "BLOCKED": "✗", "DONE_WITH_CONCERNS": "⚠", "NEEDS_CONTEXT": "?"
}
for sf in state_files:
    try:
        with open(sf) as f:
            s = json.load(f)
        icon = STATUS_ICON.get(s.get("status", ""), "·")
        approvals = ", ".join(s.get("approvals", [])) or "none"
        rejections = ", ".join(s.get("rejections", [])) or "none"
        print(f"  {icon} [{s['status']:22s}] {s['task_id']}")
        print(f"      owner={s.get('owner','?')}  approvals={approvals}  rejections={rejections}")
        if s.get("summary"):
            print(f"      {s['summary'][:72]}")
    except Exception as e:
        print(f"  ? [error reading {sf}]: {e}")
PYEOF
}
