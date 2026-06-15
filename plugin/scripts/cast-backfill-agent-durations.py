#!/usr/bin/env python3
"""CAST backfill script: compute duration_ms for historical agent_runs rows.

Rows that have duration_ms=0 (or NULL) but have both started_at and ended_at set
can have their duration computed retrospectively.

Duration formula (mirrors the fix in cast-subagent-stop-hook.sh):
  duration_ms = CAST(
    (julianday(replace(replace(ended_at,'T',' '),'Z',''))
     - julianday(replace(replace(started_at,'T',' '),'Z','')))
    * 86400000 AS INTEGER
  )

ISO-8601 timestamps are normalised before julianday() by replacing 'T' with a space
and stripping the trailing 'Z', which SQLite's julianday() requires.

Usage:
  python3 cast-backfill-agent-durations.py              # dry-run (default, no writes)
  python3 cast-backfill-agent-durations.py --apply      # write to DB
  python3 cast-backfill-agent-durations.py --db /path/to/cast.db --apply
"""
import argparse
import os
import sqlite3
import sys


def get_db_path(db_arg: str | None) -> str:
    """Resolve the DB path from --db arg, CAST_DB_PATH env, or default."""
    if db_arg:
        return db_arg
    return os.path.expanduser(
        os.environ.get("CAST_DB_PATH", "~/.claude/cast.db")
    )


COUNT_SQL = """
SELECT COUNT(*)
FROM agent_runs
WHERE duration_ms = 0
  AND ended_at IS NOT NULL
  AND started_at IS NOT NULL
"""

DRY_RUN_SQL = """
SELECT
    id,
    agent,
    started_at,
    ended_at,
    CAST(
        (julianday(replace(replace(ended_at,  'T', ' '), 'Z', ''))
         - julianday(replace(replace(started_at, 'T', ' '), 'Z', '')))
        * 86400000 AS INTEGER
    ) AS computed_duration_ms
FROM agent_runs
WHERE duration_ms = 0
  AND ended_at IS NOT NULL
  AND started_at IS NOT NULL
ORDER BY id
LIMIT 10
"""

UPDATE_SQL = """
UPDATE agent_runs
SET duration_ms = CAST(
    (julianday(replace(replace(ended_at,  'T', ' '), 'Z', ''))
     - julianday(replace(replace(started_at, 'T', ' '), 'Z', '')))
    * 86400000 AS INTEGER
)
WHERE duration_ms = 0
  AND ended_at IS NOT NULL
  AND started_at IS NOT NULL
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Backfill duration_ms for agent_runs rows where it is 0 but timestamps exist."
    )
    parser.add_argument(
        "--db",
        default=None,
        help="Path to cast.db (default: $CAST_DB_PATH or ~/.claude/cast.db)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write changes to the DB. Without this flag the script runs in dry-run mode.",
    )
    args = parser.parse_args()

    db_path = get_db_path(args.db)
    dry_run = not args.apply

    print(f"DB:      {db_path}")
    print(f"Mode:    {'DRY-RUN (no writes)' if dry_run else 'APPLY (will write)'}")
    print()

    if not os.path.isfile(db_path):
        print(f"ERROR: DB file not found: {db_path}", file=sys.stderr)
        return 1

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except sqlite3.Error as e:
        # fake-success-ok: genuine error surface — prints to stderr and exits non-zero
        print(f"ERROR: cannot open DB: {e}", file=sys.stderr)
        return 1

    try:
        row = conn.execute(COUNT_SQL).fetchone()
        affected = row[0] if row else 0
        print(f"Rows that WOULD be updated (duration_ms=0, both timestamps present): {affected}")
        print()

        if affected > 0:
            print("Sample rows (up to 10) — computed values:")
            print(f"  {'id':>6}  {'agent':<20}  {'started_at':25}  {'ended_at':25}  {'computed_ms':>12}")
            print(f"  {'-'*6}  {'-'*20}  {'-'*25}  {'-'*25}  {'-'*12}")
            for row in conn.execute(DRY_RUN_SQL).fetchall():
                row_id, agent, started_at, ended_at, computed_ms = row
                print(
                    f"  {row_id:>6}  {(agent or 'unknown'):<20}  {(started_at or ''):<25}  "
                    f"{(ended_at or ''):<25}  {(computed_ms or 0):>12}"
                )
            print()

        if dry_run:
            print("DRY-RUN mode — no writes performed.")
            print("Re-run with --apply to commit changes.")
            conn.close()
            return 0

        # Apply the update
        conn.execute(UPDATE_SQL)
        updated = conn.execute("SELECT changes()").fetchone()[0]
        conn.commit()
        conn.close()
        print(f"Rows updated: {updated}")
        return 0

    except sqlite3.Error as e:
        # fake-success-ok: genuine error surface — prints to stderr and exits non-zero
        print(f"ERROR: {e}", file=sys.stderr)
        try:
            conn.close()  # fake-success-ok: best-effort close; ignore if already closed
        except Exception:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(main())
