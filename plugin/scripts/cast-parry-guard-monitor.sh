#!/bin/bash
# cast-parry-guard-monitor.sh — Daily parry-guard rejection monitor
#
# Usage: bash scripts/cast-parry-guard-monitor.sh
#
# Queries cast.db for parry_guard_events in the last 24 hours,
# flags tools with >=3 rejections as possible false positives,
# writes daily log to ~/.claude/logs/parry-guard-daily-YYYY-MM-DD.log
#
# Register a daily schedule (7-day watch period):
#   /schedule --frequency daily --at 07:00 --duration 7d \
#   bash ~/Projects/personal/claude-agent-team/scripts/cast-parry-guard-monitor.sh

# Guard: do not re-trigger in subagent contexts
if [[ "${CLAUDE_SUBPROCESS:-0}" = "1" ]]; then exit 0; fi

set -euo pipefail

# Setup paths
LOGS_DIR="$HOME/.claude/logs"
REPORT_DATE=$(date +%Y-%m-%d)
REPORT_FILE="$LOGS_DIR/parry-guard-daily-${REPORT_DATE}.log"

# Create logs directory
mkdir -p "$LOGS_DIR"

# Query parry_guard_events from the last 24 hours using cast_db.py
# CAST_DB_PATH is passed to Python subprocess
QUERY_RESULT=$(CAST_DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}" python3 -c "
import sqlite3
import os
import sys
from datetime import datetime, timedelta

db_path = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))

try:
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    # Check if table exists
    cursor.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name='parry_guard_events'\")
    if not cursor.fetchone():
        print('TABLE_NOT_FOUND', file=sys.stderr)
        sys.exit(0)

    # Query events from last 24 hours
    cursor.execute('''
        SELECT tool_name, input_snippet, rejected_at
        FROM parry_guard_events
        WHERE rejected_at > datetime('now', '-1 day')
        ORDER BY rejected_at DESC
        LIMIT 50
    ''')

    rows = cursor.fetchall()

    # Group by tool_name
    tool_counts = {}
    events = []

    for row in rows:
        tool = row['tool_name']
        snippet = row['input_snippet'] or ''
        rejected_at = row['rejected_at']

        if tool not in tool_counts:
            tool_counts[tool] = 0
        tool_counts[tool] += 1

        events.append({
            'tool': tool,
            'snippet': snippet,
            'timestamp': rejected_at
        })

    # Output JSON for shell parsing
    import json
    print(json.dumps({
        'tool_counts': tool_counts,
        'events': events,
        'total_events': len(events)
    }))

    conn.close()

except Exception as e:
    import json
    print(json.dumps({
        'error': str(e),
        'tool_counts': {},
        'events': [],
        'total_events': 0
    }))
    sys.exit(0)
" 2>&1)

# Parse the JSON result
if echo "$QUERY_RESULT" | grep -q "TABLE_NOT_FOUND"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] parry_guard_events table does not exist yet. No rejections to report." | tee -a "$REPORT_FILE"
    exit 0
fi

# Parse JSON output
TOOL_COUNTS=$(echo "$QUERY_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('tool_counts',{})))" 2>/dev/null || echo '{}')
TOTAL_EVENTS=$(echo "$QUERY_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_events',0))" 2>/dev/null || echo '0')

# Write report header
{
    echo "================================================================================"
    echo "Parry-Guard Security Gate Activity Report"
    echo "Date: $REPORT_DATE"
    echo "================================================================================"
    echo ""
    echo "Total rejections (24h): $TOTAL_EVENTS"
    echo ""
} | tee -a "$REPORT_FILE"

# If no events, report that
if [ "$TOTAL_EVENTS" -eq 0 ]; then
    echo "No rejections recorded in the last 24 hours." | tee -a "$REPORT_FILE"
    exit 0
fi

# Parse tool counts and flag false positives
echo "Rejection Summary by Tool:" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

echo "$TOOL_COUNTS" | python3 -c "
import sys,json
tool_counts = json.load(sys.stdin)

if not tool_counts:
    print('(no rejections recorded)', file=sys.stderr)
    sys.exit(0)

for tool in sorted(tool_counts.keys()):
    count = tool_counts[tool]
    flag = ''
    if count >= 3:
        flag = ' [POSSIBLE FALSE POSITIVE — REVIEW RECOMMENDED]'
    print(f'  • {tool}: {count} rejection(s){flag}')
" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "================================================================================" | tee -a "$REPORT_FILE"

exit 0
