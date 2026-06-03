#!/usr/bin/env python3
"""cast-abandon-stale-runs.py — Flip stale 'running' agent_runs to 'abandoned'.

Runs daily via cron. Finds agent_runs rows that have been stuck in status='running'
for more than 2 hours and flips them to status='abandoned', recording abandoned_at.

Schema migration (idempotent — performed on first run):
  ALTER TABLE agent_runs ADD COLUMN abandoned_at TIMESTAMP;

Exit: always 0 (non-blocking; cron must not be broken by this script).

One-time backfill (review before executing — DO NOT automate):
  UPDATE agent_runs
  SET status = 'abandoned', abandoned_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  WHERE status = 'running'
    AND started_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-2 hours');
  -- Expected: ~33 rows updated. Verify count before committing.

Usage:
  python3 ~/.claude/scripts/cast-abandon-stale-runs.py
  # Or via cron (add to crontab -e):
  # 0 4 * * * python3 ~/.claude/scripts/cast-abandon-stale-runs.py
"""

import os
import sys
import sqlite3
from datetime import datetime, timedelta, timezone

# --- Config ---
DB_PATH = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
STALE_HOURS = int(os.environ.get('CAST_ABANDON_STALE_HOURS', '2'))
LOG_PATH = os.path.expanduser('~/.claude/logs/cast-abandon-stale-runs.log')


def _log(msg: str) -> None:
    """Append a timestamped line to the log file. Never fails."""
    try:
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(LOG_PATH, 'a') as f:
            f.write(f'[{ts}] {msg}\n')
    except Exception:
        pass


def main() -> None:
    if not os.path.exists(DB_PATH):
        _log(f'cast.db not found at {DB_PATH} — skipping')
        sys.exit(0)

    now_utc = datetime.now(timezone.utc)
    now_iso = now_utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    threshold_iso = (now_utc - timedelta(hours=STALE_HOURS)).strftime('%Y-%m-%dT%H:%M:%SZ')

    try:
        conn = sqlite3.connect(DB_PATH, timeout=10)
    except Exception as e:
        _log(f'DB connect failed: {e}')
        sys.exit(0)

    try:
        # Schema migration: add abandoned_at column if missing (idempotent)
        try:
            conn.execute('ALTER TABLE agent_runs ADD COLUMN abandoned_at TIMESTAMP')
            conn.commit()
            _log('Schema migration: added abandoned_at column to agent_runs')
        except sqlite3.OperationalError:
            pass  # column already exists

        # Find and flip stale running rows.
        # Use a Python-computed ISO-8601 threshold so that string comparison
        # against ISO-formatted started_at values (YYYY-MM-DDTHH:MM:SSZ) is
        # lexicographically correct.  SQLite's datetime('now') produces
        # 'YYYY-MM-DD HH:MM:SS' (space separator, no Z) which does NOT sort
        # correctly against ISO-8601 strings and would break cast-db-verify C5/C7.
        cursor = conn.execute(
            '''
            SELECT id, agent, started_at
            FROM agent_runs
            WHERE status = 'running'
              AND started_at < ?
            ''',
            (threshold_iso,)
        )
        stale_rows = cursor.fetchall()

        if not stale_rows:
            _log('No stale running rows found')
            conn.close()
            sys.exit(0)

        row_ids = [row[0] for row in stale_rows]
        conn.execute(
            f'''
            UPDATE agent_runs
            SET status = 'abandoned', abandoned_at = ?
            WHERE id IN ({",".join("?" * len(row_ids))})
            ''',
            [now_iso] + row_ids
        )
        conn.commit()

        for row_id, agent, started_at in stale_rows:
            _log(f'Abandoned: id={row_id} agent={agent} started_at={started_at}')

        _log(f'Flipped {len(stale_rows)} stale running row(s) to abandoned')
        print(f'[cast-abandon-stale-runs] Abandoned {len(stale_rows)} stale run(s)', file=sys.stderr)

    except Exception as e:
        _log(f'Error during cleanup: {e}')
    finally:
        try:
            conn.close()
        except Exception:
            pass

    sys.exit(0)


if __name__ == '__main__':
    main()
