#!/bin/bash
# cast-board.sh — CAST Cross-Session Project Board
# Reads all events from ~/.claude/cast/events/ and derives persistent task state.
# Writes ~/.claude/cast/project-board.json with:
#   - blocked_tasks: tasks BLOCKED for >1 session
#   - in_flight_tasks: tasks claimed but not completed
#   - top_agents: top 3 most-dispatched agents across all sessions
#
# Usage:
#   cast-board.sh        # Derive state and write project-board.json
#   cast-board.sh --cat  # Write then print the board JSON to stdout

set -euo pipefail

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
BOARD_PATH="${CAST_DIR}/project-board.json"

DO_PRINT="${1:-}"

# Ensure cast dir exists
mkdir -p "$CAST_DIR"

if [ ! -d "$EVENTS_DIR" ]; then
  # No events yet — write empty board
  python3 -c "
import json, datetime
board = {
  'updated_at': datetime.datetime.utcnow().isoformat() + 'Z',
  'event_count': 0,
  'blocked_tasks': [],
  'in_flight_tasks': [],
  'top_agents': []
}
import os
board_path = os.path.expanduser('~/.claude/cast/project-board.json')
with open(board_path, 'w') as f:
  json.dump(board, f, indent=2)
print('Board written (no events):', board_path)
"
  exit 0
fi

python3 -c "
import json, os, sys, datetime, glob
from collections import defaultdict, Counter

events_dir = os.path.expanduser('~/.claude/cast/events')
board_path = os.path.expanduser('~/.claude/cast/project-board.json')

# Read all event files
events = []
event_files = sorted(glob.glob(os.path.join(events_dir, '*.json')))
for fpath in event_files:
    try:
        with open(fpath) as f:
            event = json.load(f)
        events.append(event)
    except Exception:
        continue

# Sort by timestamp
events.sort(key=lambda e: e.get('timestamp', ''))

# Replay events to derive task state
# task_id is the 'batch' field or a combo of agent+batch
task_state = {}  # task_id -> {status, agent, batch, last_ts, blocked_count}
agent_dispatch_counts = Counter()

for event in events:
    etype = event.get('type', '')
    agent = event.get('agent', '')
    batch = event.get('batch', '')
    ts = event.get('timestamp', '')
    msg = event.get('message', '')

    # Build task_id from batch+agent
    task_id = f'{batch}:{agent}' if batch and agent else (batch or agent or 'unknown')

    if agent and etype in ('task_claimed', 'task_completed', 'task_blocked'):
        agent_dispatch_counts[agent] += 1

    if etype == 'task_claimed':
        if task_id not in task_state:
            task_state[task_id] = {
                'task_id': task_id,
                'agent': agent,
                'batch': batch,
                'status': 'in_flight',
                'first_ts': ts,
                'last_ts': ts,
                'blocked_count': 0,
                'message': msg
            }
        else:
            task_state[task_id]['status'] = 'in_flight'
            task_state[task_id]['last_ts'] = ts

    elif etype == 'task_completed':
        if task_id in task_state:
            task_state[task_id]['status'] = 'completed'
            task_state[task_id]['last_ts'] = ts
        else:
            # Completed without claim event — mark as completed
            task_state[task_id] = {
                'task_id': task_id,
                'agent': agent,
                'batch': batch,
                'status': 'completed',
                'first_ts': ts,
                'last_ts': ts,
                'blocked_count': 0,
                'message': msg
            }

    elif etype == 'task_blocked':
        if task_id in task_state:
            task_state[task_id]['status'] = 'blocked'
            task_state[task_id]['last_ts'] = ts
            task_state[task_id]['blocked_count'] = task_state[task_id].get('blocked_count', 0) + 1
        else:
            task_state[task_id] = {
                'task_id': task_id,
                'agent': agent,
                'batch': batch,
                'status': 'blocked',
                'first_ts': ts,
                'last_ts': ts,
                'blocked_count': 1,
                'message': msg
            }

now = datetime.datetime.utcnow()

# Derive categories
blocked_tasks = []
in_flight_tasks = []

for task_id, state in task_state.items():
    if state['status'] == 'blocked':
        # Calculate age
        try:
            last_dt = datetime.datetime.fromisoformat(state['last_ts'].rstrip('Z'))
            age_hours = (now - last_dt).total_seconds() / 3600
        except Exception:
            age_hours = 0
        blocked_tasks.append({
            **state,
            'age_hours': round(age_hours, 1)
        })
    elif state['status'] == 'in_flight':
        try:
            last_dt = datetime.datetime.fromisoformat(state['last_ts'].rstrip('Z'))
            age_hours = (now - last_dt).total_seconds() / 3600
        except Exception:
            age_hours = 0
        in_flight_tasks.append({
            **state,
            'age_hours': round(age_hours, 1)
        })

# Sort blocked by age descending (oldest first)
blocked_tasks.sort(key=lambda t: t.get('age_hours', 0), reverse=True)
in_flight_tasks.sort(key=lambda t: t.get('age_hours', 0), reverse=True)

# Top 3 agents by dispatch count
top_agents = [
    {'agent': agent, 'dispatch_count': count}
    for agent, count in agent_dispatch_counts.most_common(3)
]

board = {
    'updated_at': now.isoformat() + 'Z',
    'event_count': len(events),
    'blocked_tasks': blocked_tasks,
    'in_flight_tasks': in_flight_tasks,
    'top_agents': top_agents
}

# Stale rollback refs: batch-*.sha files in ~/.claude/cast/rollback/ older than 7 days
stale_rollback_refs = []
rollback_dir = os.path.expanduser('~/.claude/cast/rollback')
if os.path.isdir(rollback_dir):
    import time as _time
    now_ts = _time.time()
    seven_days_sec = 7 * 24 * 3600
    for sha_file in glob.glob(os.path.join(rollback_dir, 'batch-*.sha')):
        try:
            age_sec = now_ts - os.path.getmtime(sha_file)
            if age_sec > seven_days_sec:
                basename = os.path.basename(sha_file)
                batch_id = basename.replace('batch-', '').replace('.sha', '')
                age_days = round(age_sec / 86400, 1)
                stale_rollback_refs.append({
                    'batch_id': batch_id,
                    'sha_file': sha_file,
                    'age_days': age_days
                })
        except Exception:
            continue
    stale_rollback_refs.sort(key=lambda r: r['age_days'], reverse=True)

board['stale_rollback_refs'] = stale_rollback_refs

with open(board_path, 'w') as f:
    json.dump(board, f, indent=2)

print(f'Board written: {board_path}')
print(f'Events replayed: {len(events)}')
print(f'Blocked tasks: {len(blocked_tasks)}')
print(f'In-flight tasks: {len(in_flight_tasks)}')
print(f'Top agents: {[a[\"agent\"] for a in top_agents]}')
print(f'Stale rollback refs: {len(stale_rollback_refs)}')

if stale_rollback_refs:
    stale_ids = ', '.join(r['batch_id'] for r in stale_rollback_refs)
    print(f'WARNING Stale rollback refs: batches [{stale_ids}] have unresolved checkpoints — run cast-rollback.sh --batch <id> to review or clean up.')

do_print = os.environ.get('CAST_BOARD_PRINT', '0')
if do_print == '1':
    print(json.dumps(board, indent=2))
" 2>/dev/null || true

if [ "$DO_PRINT" = "--cat" ]; then
  if [ -f "$BOARD_PATH" ]; then
    cat "$BOARD_PATH"
  fi
fi

exit 0
