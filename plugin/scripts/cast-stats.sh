#!/bin/bash
# cast-stats.sh — CAST routing analytics and gap report
# Reads routing-log.jsonl and surfaces:
# 1. Top 10 unmatched prompts (no_match events)
# 2. Route match frequency
# 3. Loop breaks and escalations
# 4. Agent dispatch counts
# 5. Event lifecycle summary

set -euo pipefail

LOG_FILE="${HOME}/.claude/routing-log.jsonl"

# --brief mode: output a single status line for statusLine setting
if [ "${1:-}" = "--brief" ]; then
  TODAY=$(date +%Y%m%d)
  EVENTS_DIR="${HOME}/.claude/cast/events"
  CAST_LOG_DIR="${HOME}/.claude/cast"
  agents_today=$(ls "$EVENTS_DIR" 2>/dev/null | { grep -c "^${TODAY}T.*subagent-stop\.json$" || true; })
  # Count dispatches from events dir (subagent-stop files = completed agent runs, all time)
  dispatches=$(ls "$EVENTS_DIR" 2>/dev/null | { grep -c "subagent-stop\.json$" || true; })
  # Measure total size of active CAST log files (~/.claude/cast/*.jsonl)
  # Use find+xargs to avoid glob-no-match failure under set -e on Linux
  bytes=$(find "${CAST_LOG_DIR}" -maxdepth 1 -name '*.jsonl' 2>/dev/null | xargs cat 2>/dev/null | wc -c | tr -d '[:space:]')
  bytes=${bytes:-0}
  mb=$(awk "BEGIN{printf \"%.1f\", ${bytes}/1048576}")
  printf "CAST | agents:%d today  dispatches:%d | log: %sMB\n" "$agents_today" "$dispatches" "$mb"
  exit 0
fi

if [ ! -f "$LOG_FILE" ]; then
  echo "No routing log found at $LOG_FILE"
  echo "CAST routing events will appear here once you start using CAST agents."
  exit 0
fi

python3 - "$LOG_FILE" <<'PYEOF'
import json, sys
from collections import Counter

log_path = sys.argv[1]
entries = []
for line in open(log_path):
    line = line.strip()
    if not line:
        continue
    try:
        entries.append(json.loads(line))
    except Exception:
        continue

if not entries:
    print("Routing log is empty.")
    sys.exit(0)

print(f"CAST Routing Analytics — {len(entries)} total events")
print("=" * 60)

# 1. Unmatched prompts
no_match = [e for e in entries if e.get('action') == 'no_match']
if no_match:
    print(f"\n--- Unmatched Prompts ({len(no_match)} total) ---")
    unmatched = Counter(e.get('prompt_preview', '')[:60] for e in no_match)
    for prompt, count in unmatched.most_common(10):
        print(f"  {count:3d}x  {prompt}")
else:
    print("\n--- No unmatched prompts (all prompts routed successfully) ---")

# 2. Route match frequency
matched = [e for e in entries if e.get('action') in ('matched', 'dispatched')]
if matched:
    print(f"\n--- Route Match Frequency ({len(matched)} total) ---")
    route_counts = Counter(e.get('matched_route', '') for e in matched)
    for route, count in route_counts.most_common(15):
        print(f"  {count:3d}x  {route}")

# 3. Agent dispatch events (from cast_emit_event mirroring)
dispatches = [e for e in entries if e.get('action') == 'agent_dispatch']
completions = [e for e in entries if e.get('action') == 'agent_complete']
blocked = [e for e in entries if e.get('action') == 'agent_blocked']
if dispatches or completions or blocked:
    print(f"\n--- Agent Lifecycle Events ---")
    print(f"  Dispatched: {len(dispatches)}")
    print(f"  Completed:  {len(completions)}")
    print(f"  Blocked:    {len(blocked)}")
    if dispatches:
        agent_counts = Counter(e.get('agent_name', e.get('matched_route', '')) for e in dispatches)
        print(f"\n  Agent dispatch breakdown:")
        for agent, count in agent_counts.most_common(10):
            print(f"    {count:3d}x  {agent}")

# 4. Loop breaks
loops = [e for e in entries if e.get('action') == 'loop_break']
if loops:
    print(f"\n--- Loop Breaks ({len(loops)}) ---")
    for e in loops[-5:]:
        print(f"  {e.get('timestamp', '?')}  {e.get('matched_route', '?')}  (count: {e.get('dispatch_count', '?')})")

# 5. Model escalations
escalations = [e for e in entries if e.get('action') in ('model_escalation', 'opus_escalation')]
if escalations:
    print(f"\n--- Model Escalations ({len(escalations)}) ---")
    for e in escalations[-5:]:
        print(f"  {e.get('timestamp', '?')}  {e.get('matched_route', '?')}")

# 6. Group dispatches
groups = [e for e in entries if e.get('action') == 'group_dispatched']
if groups:
    print(f"\n--- Group Dispatches ({len(groups)}) ---")
    group_counts = Counter(e.get('matched_route', '') for e in groups)
    for group, count in group_counts.most_common(10):
        print(f"  {count:3d}x  {group}")

# 7. Catchall dispatches
catchalls = [e for e in entries if e.get('action') == 'catchall_dispatched']
if catchalls:
    print(f"\n--- Catchall Router Dispatches ({len(catchalls)}) ---")
    for e in catchalls[-5:]:
        print(f"  {e.get('prompt_preview', '?')[:50]}")

# 8. Config errors
errors = [e for e in entries if e.get('action') == 'config_error']
if errors:
    print(f"\n--- Config Errors ({len(errors)}) ---")
    for e in errors[-3:]:
        print(f"  {e.get('timestamp', '?')}: {e.get('error', '?')}")

print(f"\n{'=' * 60}")
print(f"Total: {len(entries)} events | Log file: {log_path}")
size_mb = __import__('os').path.getsize(log_path) / (1024 * 1024)
print(f"Log size: {size_mb:.1f} MB")
PYEOF
