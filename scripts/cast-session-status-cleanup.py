#!/usr/bin/env python3
"""cast-session-status-cleanup.py — Periodic session crash detection.

Flips sessions.status from 'active' to 'crashed' where:
  - status = 'active'
  - started_at < NOW() - 4 hours (session started but never marked ended)

Add to cron (daily at 5am):
  0 5 * * * python3 ~/.claude/scripts/cast-session-status-cleanup.py

ONE-TIME BACKFILL (review before executing — DO NOT run in this script):
  UPDATE sessions
  SET status = CASE
    WHEN end_at IS NOT NULL OR ended_at IS NOT NULL THEN 'ended'
    ELSE 'crashed'
  END
  WHERE status IS NULL OR status = 'ended';
  -- Review: marks existing rows without ended_at as crashed.
  -- Expected: varies. Verify count before executing.
"""
import os
import sqlite3
import datetime
import sys
from pathlib import Path


def main() -> None:
    db_path = os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))

    if not Path(db_path).exists():
        print(f'[cast-session-status-cleanup] DB not found: {db_path}', file=sys.stderr)
        sys.exit(0)

    try:
        conn = sqlite3.connect(db_path, timeout=5)

        # Idempotently add status column if missing
        try:
            conn.execute("ALTER TABLE sessions ADD COLUMN status TEXT DEFAULT 'ended'")
            conn.commit()
        except Exception:
            pass  # Column already exists — fine

        result = conn.execute(
            """UPDATE sessions
               SET status = 'crashed'
               WHERE status = 'active'
                 AND started_at < datetime('now', '-4 hours')""",
        )
        crashed_count = result.rowcount
        conn.commit()
        conn.close()

        ts = datetime.datetime.utcnow().isoformat() + 'Z'
        print(f'[{ts}] cast-session-status-cleanup: flipped {crashed_count} active → crashed')

    except Exception as e:
        ts = datetime.datetime.utcnow().isoformat() + 'Z'
        log_dir = Path.home() / '.claude' / 'logs'
        log_dir.mkdir(parents=True, exist_ok=True)
        with open(log_dir / 'db-write-errors.log', 'a') as f:
            f.write(f'[{ts}] ERROR cast-session-status-cleanup.py: {e}\n')
        print(f'[cast-session-status-cleanup] Error: {e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
