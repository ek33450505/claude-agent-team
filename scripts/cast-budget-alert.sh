#!/bin/bash
# cast-budget-alert.sh — CAST budget guard hook
# Called after cast-cost-tracker.sh updates the DB.
# Reads today's total spend from sessions table and compares against
# budgets table (scope='global', period='daily').
#
# Outputs:
#   [CAST-BUDGET-WARN]       — when spend >= alert_at_pct of limit
#   [CAST-BUDGET-HARD-LIMIT] — when spend >= limit (route only to local models)
#
# Silent on error or when no budget is configured.
# Never blocks Claude Code (exits 0 always).

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# Nothing to do if db doesn't exist
if [ ! -f "$DB_PATH" ]; then
  exit 0
fi

DB_PATH_VAL="$DB_PATH" \
CLAUDE_SESSION_ID_VAL="${CLAUDE_SESSION_ID:-unknown}" \
python3 - <<'PYEOF' 2>/dev/null || true

import json, os, sys, sqlite3, datetime

db_path    = os.environ.get('DB_PATH_VAL', '')
session_id = os.environ.get('CLAUDE_SESSION_ID_VAL', 'unknown')

if not db_path or not os.path.exists(db_path):
    sys.exit(0)

try:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur  = conn.cursor()

    # -----------------------------------------------------------------------
    # 1. Look up global daily budget (most specific match wins)
    # -----------------------------------------------------------------------
    cur.execute('''
        SELECT limit_usd, alert_at_pct
        FROM budgets
        WHERE scope = 'global' AND period = 'daily'
        ORDER BY id DESC
        LIMIT 1
    ''')
    budget_row = cur.fetchone()

    if not budget_row:
        conn.close()
        sys.exit(0)

    limit_usd    = float(budget_row['limit_usd'] or 0)
    alert_at_pct = float(budget_row['alert_at_pct'] or 0.80)

    if limit_usd <= 0:
        conn.close()
        sys.exit(0)

    # -----------------------------------------------------------------------
    # 2. Sum today's spend from sessions table
    # -----------------------------------------------------------------------
    today = datetime.date.today().isoformat()
    cur.execute('''
        SELECT COALESCE(SUM(total_cost_usd), 0.0)
        FROM sessions
        WHERE started_at LIKE ? || '%'
    ''', (today,))
    today_spend = float(cur.fetchone()[0] or 0)
    conn.close()

    if today_spend <= 0:
        sys.exit(0)

    pct_used = today_spend / limit_usd

    # -----------------------------------------------------------------------
    # 3. Emit directive based on threshold
    # -----------------------------------------------------------------------
    if pct_used >= 1.0:
        # Hard limit exceeded
        msg = (
            f'[CAST-BUDGET-HARD-LIMIT] Daily spend ${today_spend:.4f} has reached the '
            f'${limit_usd:.2f} daily budget limit ({pct_used*100:.0f}%). '
            'MANDATORY: Pause all agent dispatches until the budget resets at midnight UTC.'
        )
    elif pct_used >= alert_at_pct:
        # Warning threshold reached
        remaining = limit_usd - today_spend
        msg = (
            f'[CAST-BUDGET-WARN] Daily spend ${today_spend:.4f} is {pct_used*100:.0f}% '
            f'of the ${limit_usd:.2f} daily budget (${remaining:.4f} remaining). '
            'Consider routing lighter tasks to local models to conserve budget.'
        )
    else:
        sys.exit(0)

    output = {
        'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': msg
        }
    }
    print(json.dumps(output))

except Exception:
    pass

PYEOF

exit 0
