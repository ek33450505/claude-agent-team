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
  local status="${6:-}"
  local concerns="${7:-}"

  _cast_init_dirs

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local ts_iso
  ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local event_file="${CAST_EVENTS_DIR}/${ts}-${agent}-${task_id}.json"

  python3 - "$event_type" "$agent" "$task_id" "$artifact_id" "$summary" "$status" "$concerns" "$ts" "$event_file" "$ts_iso" <<'PYEOF'
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
    CAST_SUMMARY="$summary" CAST_STATUS="$status" CAST_TS="$ts_iso" \
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
    'action':         action,
    'matched_route':  agent,
    'agent_name':     agent,
    'prompt_preview': summary[:80] if summary else task_id,
    'command':        None,
    'pattern':        'cast_event',
    'confidence':     'hard',
    'status':         status if status else None,
    'task_id':        task_id,
}
import subprocess
subprocess.run(
    ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
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
cast_check_approvals() {
  local task_id="$1"
  shift
  local required=("$@")

  cast_derive_state "$task_id" >/dev/null 2>&1

  local safe_task="${task_id//\//-}"
  local state_file="${CAST_STATE_DIR}/${safe_task}.json"
  [ -f "$state_file" ] || { echo "No state for task: $task_id" >&2; return 1; }

  python3 - "$state_file" "${required[@]}" <<'PYEOF'
import json, sys
state_file = sys.argv[1]
required = sys.argv[2:]
with open(state_file) as f:
    state = json.load(f)
approvals = set(state.get("approvals", []))
rejections = set(state.get("rejections", []))
if rejections:
    print(f"REJECTED by: {', '.join(rejections)}", file=sys.stderr)
    sys.exit(2)
missing = [r for r in required if r not in approvals]
if missing:
    print(f"Missing approvals from: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
print("All required approvals present")
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
