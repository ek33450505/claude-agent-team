#!/usr/bin/env python3
"""CAST backfill script: fix task_queue rows stuck with status='running'.

Background
----------
cast-task-created-hook.sh previously INSERTed new rows with status='running',
but cast-queue-processor.sh only claims rows WHERE status='pending'. The FSM
is: pending → claimed → done | failed | pending (retry). 'running' is not a
valid initial state in this FSM, so every hook-created row was permanently
unclaimable.

The hook has been fixed to INSERT status='pending' going forward. This script
backfills existing orphaned 'running' rows to 'pending' so the processor can
claim them when it is eventually scheduled.

NOTE: The processor (cast-queue-processor.sh) is currently NOT scheduled on
any cron/launchd. Running --apply here will update the rows but tasks will not
be dispatched until the processor is wired up — that is an operational decision
deferred intentionally.

Usage
-----
  # See what would change (safe, default)
  python3 cast-backfill-task-queue-status.py --dry-run

  # Apply the fix
  python3 cast-backfill-task-queue-status.py --apply

  # Target a specific DB
  python3 cast-backfill-task-queue-status.py --apply --db /path/to/cast.db
"""
import argparse
import os
import sqlite3
import sys


def get_db_path(db_arg: str | None) -> str:
    """Resolve DB path from --db arg, CAST_DB_PATH env, or default."""
    if db_arg:
        return db_arg
    return os.path.expanduser(
        os.environ.get("CAST_DB_PATH", "~/.claude/cast.db")
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Backfill task_queue rows with status='running' → 'pending' "
            "so the queue processor can claim them."
        )
    )
    parser.add_argument(
        "--db",
        default=None,
        help="Path to cast.db (default: $CAST_DB_PATH or ~/.claude/cast.db)",
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--dry-run",
        action="store_true",
        default=True,
        help="Report how many rows WOULD change without writing (default).",
    )
    mode_group.add_argument(
        "--apply",
        action="store_true",
        default=False,
        help="Run the UPDATE for real.",
    )
    args = parser.parse_args()

    # --apply overrides the default --dry-run=True
    dry_run = not args.apply

    db_path = get_db_path(args.db)
    print(f"DB:      {db_path}")
    print(f"Mode:    {'DRY-RUN (no writes)' if dry_run else 'APPLY (will write)'}")
    print()

    if not os.path.exists(db_path):
        print(f"[ERROR] DB not found: {db_path}", file=sys.stderr)
        return 1

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except sqlite3.Error as e:
        # fake-success-ok: intentional — prints [ERROR] to stderr and returns exit 1; not masking
        print(f"[ERROR] Cannot connect to DB: {e}", file=sys.stderr)
        return 1

    try:
        cur = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='task_queue'"
        )
        if not cur.fetchone():
            print("[INFO] table task_queue does not exist — nothing to do.")
            conn.close()
            return 0

        cur = conn.execute("SELECT COUNT(*) FROM task_queue WHERE status='running'")
        running_count = cur.fetchone()[0]

        print(f"Rows with status='running': {running_count}")

        if running_count == 0:
            print("Nothing to backfill.")
            conn.close()
            return 0

        # Show a sample for context
        sample_cur = conn.execute(
            "SELECT id, agent, task, created_at FROM task_queue "
            "WHERE status='running' ORDER BY created_at ASC LIMIT 5"
        )
        sample = sample_cur.fetchall()
        print("Sample rows (up to 5, oldest first):")
        for row_id, agent, task, created_at in sample:
            print(f"  id={row_id}  agent={agent}  created={created_at}  task={task!r:.60}")
        print()

        if dry_run:
            print(f"DRY-RUN: would UPDATE {running_count} rows "
                  f"SET status='pending' WHERE status='running'.")
            print()
            print("NOTE: the queue processor (cast-queue-processor.sh) is currently NOT")
            print("scheduled on any cron/launchd. After --apply, rows become claimable")
            print("but will NOT be dispatched until the processor is wired up.")
        else:
            with conn:
                conn.execute(
                    "UPDATE task_queue SET status='pending' WHERE status='running'"
                )
            # Verify
            cur2 = conn.execute("SELECT changes()")
            updated = cur2.fetchone()[0]
            print(f"Updated {running_count} rows (status='running' → 'pending').")
            print()
            print("NOTE: the queue processor (cast-queue-processor.sh) is currently NOT")
            print("scheduled on any cron/launchd. These rows are now claimable but will")
            print("NOT be dispatched until the processor is wired up (operational decision).")

    except sqlite3.Error as e:
        # fake-success-ok: intentional — prints [ERROR] to stderr and returns exit 1; not masking
        print(f"[ERROR] DB operation failed: {e}", file=sys.stderr)
        conn.close()
        return 1

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
