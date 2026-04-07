#!/usr/bin/env python3
"""
cast-memory-migrate-temporal.py — Idempotent migration to add temporal validity columns.

Adds valid_from and valid_to columns to agent_memories table in cast.db.
Safe to re-run — checks for column existence before altering.

Usage:
  python3 scripts/cast-memory-migrate-temporal.py [--db <path>]

Exit codes:
  0 — success (columns added or already present)
  1 — failure (DB error)
"""

import sys
import os
import argparse
import sqlite3


def migrate(db_path):
    """Run temporal validity migration. Returns (columns_added, rows_backfilled)."""
    conn = sqlite3.connect(db_path)
    try:
        # Check existing columns via PRAGMA table_info
        cursor = conn.execute("PRAGMA table_info(agent_memories)")
        columns = {row[1] for row in cursor.fetchall()}

        if not columns:
            print("ERROR: agent_memories table not found or has no columns.", file=sys.stderr)
            conn.close()
            return None, None

        columns_added = []
        rows_backfilled = 0

        # Add valid_from if not present
        # Note: SQLite ALTER TABLE does not support DEFAULT (datetime('now')) (non-constant).
        # We add with DEFAULT NULL and backfill immediately after.
        if 'valid_from' not in columns:
            conn.execute(
                "ALTER TABLE agent_memories ADD COLUMN valid_from TEXT DEFAULT NULL"
            )
            columns_added.append('valid_from')
            print("Added column: valid_from")

        # Add valid_to if not present
        if 'valid_to' not in columns:
            conn.execute(
                "ALTER TABLE agent_memories ADD COLUMN valid_to TEXT DEFAULT NULL"
            )
            columns_added.append('valid_to')
            print("Added column: valid_to")

        # Backfill valid_from for rows where valid_from IS NULL.
        # Use created_at if available, otherwise fall back to datetime('now').
        if 'valid_from' not in columns or 'valid_from' in columns_added:
            # Either we just added it (all rows need backfill) or we added it
            result = conn.execute("""
                UPDATE agent_memories
                SET valid_from = COALESCE(created_at, datetime('now'))
                WHERE valid_from IS NULL
            """)
            rows_backfilled = result.rowcount
            if rows_backfilled > 0:
                print(f"Backfilled valid_from for {rows_backfilled} rows.")

        conn.commit()
        conn.close()
        return columns_added, rows_backfilled

    except Exception as e:
        print(f"ERROR: Migration failed: {e}", file=sys.stderr)
        try:
            conn.close()
        except Exception:
            pass
        return None, None


def main():
    parser = argparse.ArgumentParser(
        description='Idempotent migration: add valid_from/valid_to to agent_memories'
    )
    parser.add_argument('--db', type=str, default=None,
                        help='Path to cast.db (default: ~/.claude/cast.db or $CAST_DB_PATH)')
    args = parser.parse_args()

    db_path = args.db or os.environ.get('CAST_DB_PATH',
                                         os.path.expanduser('~/.claude/cast.db'))

    if not os.path.exists(db_path):
        print(f"ERROR: Database not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    columns_added, rows_backfilled = migrate(db_path)

    if columns_added is None:
        sys.exit(1)

    if not columns_added:
        print("Migration already applied — valid_from and valid_to columns exist.")
    else:
        print(f"Migration complete: added {len(columns_added)} column(s), "
              f"backfilled {rows_backfilled or 0} rows.")

    sys.exit(0)


if __name__ == '__main__':
    main()
