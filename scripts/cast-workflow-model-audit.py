#!/usr/bin/env python3
"""Fleet-level trend audit for workflow-subagent model routing (2026-07-06 cost lever).

LIMITATION: this is a FLEET-LEVEL proxy, not per-stage verification. The
SubagentStop hook payload (scripts/cast_subagent_stop.py) does not expose a
label/phase field carrying the Workflow stage name, so we cannot measure
per-stage compliance with the "mechanical->haiku, analytical->sonnet,
synthesis/verify->opus" guidance in rules-core/working-conventions.md. This
script can only tell whether opus's overall share of workflow-subagent runs
has dropped week over week -- it cannot tell whether OTHER stages moved to
haiku appropriately.

Exit 0 = success (includes INFO/insufficient-data and healthy-trend cases).
Exit 1 = error, or WARN (recent-week opus% has not meaningfully improved).
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cast_db import db_query  # noqa: E402

# Baseline from the 2026-07-06 agent audit (project_cast_agent_audit_2026_07_06):
# 776/1126 workflow-subagent runs were opus-by-inheritance before PR #331 shipped
# stage-model guidance to rules-core/working-conventions.md.
BASELINE_OPUS_PCT = 776 / 1126 * 100  # 68.9%
WARN_THRESHOLD_PCT = 60.0
MIN_RUNS_FOR_TREND = 5
TRAILING_WEEKS = 4


def fetch_weekly_stats():
    sql = """
        SELECT
            strftime('%Y-%W', started_at) AS week,
            COUNT(*) AS total_runs,
            SUM(CASE WHEN model = 'claude-opus-4-8' THEN 1 ELSE 0 END) AS opus_runs,
            SUM(COALESCE(cost_usd, 0)) AS total_cost
        FROM agent_runs
        WHERE agent = 'workflow-subagent' AND started_at IS NOT NULL
        GROUP BY week
        ORDER BY week ASC
    """
    return db_query(sql)


def main() -> int:
    rows = fetch_weekly_stats()
    if not rows:
        print('INFO: no workflow-subagent runs found', file=sys.stderr)
        return 0

    weeks = []
    for r in rows:
        total = r['total_runs']
        opus = r['opus_runs'] or 0
        cost = r['total_cost'] or 0.0
        opus_pct = (opus / total * 100) if total else 0.0
        avg_cost = (cost / total) if total else 0.0
        weeks.append({
            'week': r['week'],
            'total_runs': total,
            'opus_runs': opus,
            'opus_pct': opus_pct,
            'total_cost': cost,
            'avg_cost': avg_cost,
        })

    print(f"{'week':<10} {'runs':>6} {'opus':>6} {'opus_pct':>9} {'total_cost':>12} {'avg_cost':>10}")
    for w in weeks:
        print(
            f"{w['week']:<10} {w['total_runs']:>6} {w['opus_runs']:>6} "
            f"{w['opus_pct']:>8.1f}% {w['total_cost']:>11.2f} {w['avg_cost']:>10.4f}"
        )

    recent = weeks[-1]
    if recent['total_runs'] < MIN_RUNS_FOR_TREND:
        print(
            f"INFO: insufficient data ({recent['total_runs']} runs) — skipping trend check"
        )
        return 0

    trailing = weeks[-(TRAILING_WEEKS + 1):-1] or weeks[:-1]
    if trailing:
        trailing_total = sum(w['total_runs'] for w in trailing)
        trailing_opus = sum(w['opus_runs'] for w in trailing)
        trailing_opus_pct = (trailing_opus / trailing_total * 100) if trailing_total else 0.0
    else:
        trailing_opus_pct = BASELINE_OPUS_PCT

    print(
        f"\nBaseline (pre-fix, 2026-07-06 audit): {BASELINE_OPUS_PCT:.1f}% opus\n"
        f"Trailing {len(trailing)}-week avg: {trailing_opus_pct:.1f}% opus\n"
        f"Most recent week ({recent['week']}): {recent['opus_pct']:.1f}% opus, "
        f"{recent['total_runs']} runs"
    )

    if recent['opus_pct'] >= WARN_THRESHOLD_PCT:
        print(
            f"WARN: recent-week opus% ({recent['opus_pct']:.1f}%) is still >= "
            f"{WARN_THRESHOLD_PCT:.0f}% — stage-model guidance (PR #331) does not "
            f"appear to be measurably reducing opus share."
        )
        return 1

    print(
        f"OK: recent-week opus% ({recent['opus_pct']:.1f}%) is below the "
        f"{WARN_THRESHOLD_PCT:.0f}% warn threshold."
    )
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(f'ERROR: {e}', file=sys.stderr)
        sys.exit(1)
