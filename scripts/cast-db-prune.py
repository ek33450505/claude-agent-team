#!/usr/bin/env python3
"""cast-db-prune.py — Delete rows older than CAST_DB_PRUNE_DAYS from cast.db.

Runs nightly via launchd (com.cast.db-prune). Two symmetric steps:

  Step 1 — routing_events: rows whose `timestamp` is older than DAYS days
  are deleted. (Column name is `timestamp`, NOT `created_at`.)

  Step 2 — agent_runs: rows whose `started_at` is older than DAYS days
  are deleted.

Each table's delete is wrapped in an independent try/except so a missing
table or column does NOT abort the other step or crash the script.

Dry-run mode: set CAST_DB_PRUNE_DRY_RUN=1 to report would-delete counts
without actually deleting (useful for safe verification and tests).

Retention: controlled by CAST_DB_PRUNE_DAYS (default 90). Set lower to
prune more aggressively; set higher to retain more history.

Exit: always 0 — never break cron/launchd.

Usage:
  python3 ~/.claude/scripts/cast-db-prune.py
  CAST_DB_PRUNE_DAYS=30 python3 ~/.claude/scripts/cast-db-prune.py
  CAST_DB_PRUNE_DRY_RUN=1 python3 ~/.claude/scripts/cast-db-prune.py
  # Or via launchd plist (com.cast.db-prune — runs nightly at 03:30).
"""

import os
import sys
import sqlite3
from datetime import datetime, timezone

# --- Config ---
DB_PATH: str = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
DAYS: int = int(os.environ.get('CAST_DB_PRUNE_DAYS', '90'))
DRY_RUN: bool = os.environ.get('CAST_DB_PRUNE_DRY_RUN', '0') == '1'
LOG_PATH: str = os.path.expanduser('~/.claude/logs/cron-db-prune.log')


def _log(msg: str) -> None:
    """Append a timestamped line to the log file and print to stdout. Never fails."""
    try:
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        line = f'[{ts}] {msg}'
        print(line)
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass


def _prune_table(
    conn: sqlite3.Connection,
    table: str,
    ts_col: str,
) -> int:
    """Delete (or count for dry-run) rows older than DAYS days. Returns row count.

    Uses SQLite's datetime('now', '-N days') inline so the comparison is
    evaluated inside SQLite against its own stored timestamp format.
    """
    days_expr = f"datetime('now', '-{DAYS} days')"
    if DRY_RUN:
        cursor = conn.execute(
            f"SELECT COUNT(*) FROM {table} WHERE {ts_col} < {days_expr}",
        )
        count = cursor.fetchone()[0]
        return count
    else:
        result = conn.execute(
            f"DELETE FROM {table} WHERE {ts_col} < {days_expr}",
        )
        conn.commit()
        return result.rowcount


def main() -> None:
    mode_label = '[DRY-RUN] ' if DRY_RUN else ''
    _log(f'{mode_label}cast-db-prune starting — DAYS={DAYS} db={DB_PATH}')

    if not os.path.exists(DB_PATH):
        _log(f'cast.db not found at {DB_PATH} — skipping')
        sys.exit(0)

    try:
        conn = sqlite3.connect(DB_PATH, timeout=10)
    except Exception as e:
        print(f'[cast-db-prune] DB connect failed: {e}', file=sys.stderr)
        _log(f'DB connect failed: {e}')
        sys.exit(0)

    try:
        # --- Step 1: routing_events (column: timestamp) ---
        try:
            count = _prune_table(conn, 'routing_events', 'timestamp')
            action = 'would delete' if DRY_RUN else 'deleted'
            _log(f'{mode_label}routing_events: {action} {count} row(s) older than {DAYS} days')
        except Exception as e:
            print(f'[cast-db-prune] routing_events step failed: {e}', file=sys.stderr)
            _log(f'routing_events step failed (non-fatal): {e}')

        # --- Step 2: agent_runs (column: started_at) ---
        try:
            count = _prune_table(conn, 'agent_runs', 'started_at')
            action = 'would delete' if DRY_RUN else 'deleted'
            _log(f'{mode_label}agent_runs: {action} {count} row(s) older than {DAYS} days')
        except Exception as e:
            print(f'[cast-db-prune] agent_runs step failed: {e}', file=sys.stderr)
            _log(f'agent_runs step failed (non-fatal): {e}')

    except Exception as e:
        print(f'[cast-db-prune] Unexpected error: {e}', file=sys.stderr)
        _log(f'Unexpected error: {e}')
    finally:
        try:
            conn.close()
        except Exception:
            pass

    _log(f'{mode_label}cast-db-prune finished')
    sys.exit(0)


if __name__ == '__main__':
    main()
