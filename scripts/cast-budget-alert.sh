#!/bin/bash
# cast-budget-alert.sh — CAST budget guard hook
# Wired as a SubagentStop hook, running AFTER cast-subagent-stop-hook.sh which writes
# cost_usd to agent_runs. Reads the daily SUM(cost_usd) from agent_runs and warns
# at most once per calendar day if today's spend exceeds the configured budget threshold.
#
# Outputs (to stdout as hookSpecificOutput JSON):
#   [CAST-BUDGET-WARN]       — when spend >= alert_at_pct of limit
#   [CAST-BUDGET-HARD-LIMIT] — when spend >= limit (route only to local models)
#
# Silent on error, when no budget is configured, or when today's alert already fired.
# Never blocks Claude Code (exits 0 always).

# Subprocess guard must come before set -euo pipefail
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# Nothing to do if db doesn't exist
if [ ! -f "$DB_PATH" ]; then
  exit 0
fi

# Once-per-day dedup: skip if today's alert marker already exists
CAST_STATE_DIR="${HOME}/.claude/cast"
ALERT_MARKER="${CAST_STATE_DIR}/budget-alert-$(date -u +%Y%m%d).flag"
if [ -f "$ALERT_MARKER" ]; then
  exit 0
fi

DB_PATH_VAL="$DB_PATH" \
CLAUDE_SESSION_ID_VAL="${CLAUDE_SESSION_ID:-unknown}" \
ALERT_MARKER_VAL="$ALERT_MARKER" \
CAST_STATE_DIR_VAL="$CAST_STATE_DIR" \
python3 - <<'PYEOF' 2>/dev/null || true

import json, os, sys, sqlite3, datetime

db_path       = os.environ.get('DB_PATH_VAL', '')
session_id    = os.environ.get('CLAUDE_SESSION_ID_VAL', 'unknown')
alert_marker  = os.environ.get('ALERT_MARKER_VAL', '')
state_dir     = os.environ.get('CAST_STATE_DIR_VAL', '')

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
    # 2. Sum today's spend from agent_runs (per-run cost — the same authoritative
    #    source `cast budget` reports). Previously summed sessions.total_cost_usd,
    #    which only populates when the session-end rollup runs and could lag/miss.
    # -----------------------------------------------------------------------
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    # LIKE-form works for both T/Z ISO-8601 (e.g. '2026-06-11T10:00:00Z') and
    # space-form (e.g. '2026-06-11 10:00:00') timestamps — the '%' wildcard
    # absorbs everything after the date prefix regardless of separator.
    cur.execute('''
        SELECT COALESCE(SUM(cost_usd), 0.0)
        FROM agent_runs
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

    # Atomically claim today's alert slot (O_EXCL = exactly one winner per day).
    # Concurrent SubagentStop hooks both passing the bash fast-path race here instead.
    if alert_marker and state_dir:
        try:
            os.makedirs(state_dir, exist_ok=True)
            fd = os.open(alert_marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(fd)
        except FileExistsError:
            sys.exit(0)   # another concurrent hook already claimed today's alert — stay silent
        except Exception:
            pass          # marker dir unwritable etc. — degrade gracefully, still allow the alert

        # Opportunistically remove stale markers from prior days (best-effort; never breaks hook)
        try:
            import glob
            today_flag = os.path.basename(alert_marker)
            for stale in glob.glob(os.path.join(state_dir, 'budget-alert-*.flag')):
                if os.path.basename(stale) != today_flag:
                    try:
                        os.remove(stale)
                    except Exception:
                        pass
        except Exception:
            pass

    output = {
        'hookSpecificOutput': {
            'hookEventName': 'SubagentStop',
            'additionalContext': msg
        }
    }
    print(json.dumps(output))

except Exception:
    pass

PYEOF

exit 0
