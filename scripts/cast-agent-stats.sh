#!/bin/bash
# cast-agent-stats.sh — CAST agent performance profiling tool
# Reads ~/.claude/routing-log.jsonl, filters agent_complete entries,
# and reports DONE/DONE_WITH_CONCERNS/BLOCKED/NEEDS_CONTEXT rates per agent.
#
# Usage:
#   cast-agent-stats.sh                    # all-time stats, table format
#   cast-agent-stats.sh --agent <name>     # single agent detail
#   cast-agent-stats.sh --format json      # JSON array output
#   cast-agent-stats.sh --since <N>d       # filter to last N days (e.g. --since 7d)

set -euo pipefail

LOG_PATH="${HOME}/.claude/routing-log.jsonl"

# Parse args
FILTER_AGENT=""
OUTPUT_FORMAT="table"
SINCE_DAYS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      FILTER_AGENT="$2"
      shift 2
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    --since)
      SINCE_ARG="$2"
      # Parse Nd format
      SINCE_DAYS="${SINCE_ARG%d}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

python3 - "$LOG_PATH" "$FILTER_AGENT" "$OUTPUT_FORMAT" "${SINCE_DAYS:-}" <<'PYEOF'
import sys
import json
import os
from collections import defaultdict
from datetime import datetime, timezone, timedelta

log_path = sys.argv[1]
filter_agent = sys.argv[2]
output_format = sys.argv[3]
since_days_raw = sys.argv[4] if len(sys.argv) > 4 else ''

# Build cutoff timestamp if --since provided
cutoff_dt = None
if since_days_raw:
    try:
        n = int(since_days_raw)
        cutoff_dt = datetime.now(timezone.utc) - timedelta(days=n)
    except ValueError:
        pass

if not os.path.exists(log_path):
    print("No agent_complete entries found in routing-log.jsonl")
    sys.exit(0)

# Aggregate counts: {agent: {status: count}}
counts = defaultdict(lambda: defaultdict(int))

with open(log_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        if entry.get('action') != 'agent_complete':
            continue
        route = entry.get('matched_route', '')
        status = entry.get('status', '')
        if not route or not status:
            continue
        # Apply --since filter
        if cutoff_dt:
            ts_raw = entry.get('timestamp', '')
            try:
                ts = datetime.strptime(ts_raw, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
                if ts < cutoff_dt:
                    continue
            except Exception:
                pass
        # Apply --agent filter
        if filter_agent and route != filter_agent:
            continue
        counts[route][status] += 1

if not counts:
    print("No agent_complete entries found in routing-log.jsonl")
    sys.exit(0)

STATUS_KEYS = ['DONE', 'DONE_WITH_CONCERNS', 'BLOCKED', 'NEEDS_CONTEXT']

def compute_row(agent, statuses):
    total = sum(statuses.values())
    done = statuses.get('DONE', 0)
    dwc  = statuses.get('DONE_WITH_CONCERNS', 0)
    blk  = statuses.get('BLOCKED', 0)
    needs = statuses.get('NEEDS_CONTEXT', 0)
    done_pct = (done / total * 100) if total else 0
    dwc_pct  = (dwc  / total * 100) if total else 0
    blk_pct  = (blk  / total * 100) if total else 0
    needs_pct = (needs / total * 100) if total else 0
    score = int(done_pct + dwc_pct * 0.60)
    return {
        'agent': agent,
        'runs': total,
        'done': done,
        'dwc': dwc,
        'blocked': blk,
        'needs': needs,
        'done_pct': round(done_pct),
        'dwc_pct':  round(dwc_pct),
        'blocked_pct': round(blk_pct),
        'needs_pct':  round(needs_pct),
        'score': min(score, 100),
    }

rows = [compute_row(agent, statuses) for agent, statuses in sorted(counts.items())]

if output_format == 'json':
    out = []
    for r in rows:
        out.append({
            'agent': r['agent'],
            'runs': r['runs'],
            'done_pct': r['done_pct'],
            'dwc_pct': r['dwc_pct'],
            'blocked_pct': r['blocked_pct'],
            'needs_pct': r['needs_pct'],
            'score': r['score'],
        })
    print(json.dumps(out, indent=2))
    sys.exit(0)

# Table format
label = f"all time"
if since_days_raw:
    label = f"last {since_days_raw} days"
if filter_agent:
    label += f" — {filter_agent} only"

header = f"Agent Performance Report ({label})"
print(header)
print('=' * 62)
print(f"{'Agent':<20} {'Runs':>4}  {'DONE':>5}  {'DWC':>5}  {'BLK':>5}  {'NEEDS':>5}  {'Score':>5}")
print('-' * 62)

total_runs = 0
total_done = total_dwc = total_blk = total_needs = 0

for r in rows:
    total_runs  += r['runs']
    total_done  += r['done']
    total_dwc   += r['dwc']
    total_blk   += r['blocked']
    total_needs += r['needs']
    print(f"{r['agent']:<20} {r['runs']:>4}  {r['done_pct']:>4}%  {r['dwc_pct']:>4}%  {r['blocked_pct']:>4}%  {r['needs_pct']:>4}%  {r['score']:>5}")

print('-' * 62)
if total_runs > 0:
    t_done_pct  = round(total_done  / total_runs * 100)
    t_dwc_pct   = round(total_dwc   / total_runs * 100)
    t_blk_pct   = round(total_blk   / total_runs * 100)
    t_needs_pct = round(total_needs / total_runs * 100)
    print(f"  {'Total:':<18} {total_runs:>4}  {t_done_pct:>4}%  {t_dwc_pct:>4}%  {t_blk_pct:>4}%  {t_needs_pct:>4}%")

PYEOF
