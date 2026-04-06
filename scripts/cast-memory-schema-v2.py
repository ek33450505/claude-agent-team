#!/usr/bin/env python3
"""
cast-memory-schema-v2.py — Idempotent schema migration for agent_memories.

Adds importance FLOAT DEFAULT 0.5 and decay_rate FLOAT DEFAULT 0.995 columns
if not present, then backfills type-appropriate decay rates.

Exit: 0 on success, 1 on error (details to stderr).
"""

import os
import sys
import sqlite3


def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def get_existing_columns(conn):
    """Return set of column names already in agent_memories."""
    rows = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
    return {row[1] for row in rows}


def main():
    db_path = get_db_path()

    if not os.path.exists(db_path):
        print(f"ERROR: cast.db not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except sqlite3.Error as e:
        print(f"ERROR: Cannot connect to {db_path}: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        # Check which columns already exist
        existing_cols = get_existing_columns(conn)

        added = []

        # Add importance column if missing
        if 'importance' not in existing_cols:
            conn.execute("ALTER TABLE agent_memories ADD COLUMN importance FLOAT DEFAULT 0.5")
            added.append('importance')

        # Add decay_rate column if missing
        if 'decay_rate' not in existing_cols:
            conn.execute("ALTER TABLE agent_memories ADD COLUMN decay_rate FLOAT DEFAULT 0.995")
            added.append('decay_rate')

        conn.commit()

        # Backfill type-specific decay rates for rows that still have the default 0.995
        # (Only meaningful if decay_rate column was just added or already existed at default)
        backfill_total = 0

        # feedback and user memories: stable, decay slowly
        cur = conn.execute(
            "UPDATE agent_memories SET decay_rate = 0.999 "
            "WHERE type IN ('feedback', 'user') AND decay_rate = 0.995"
        )
        backfill_total += cur.rowcount

        # project memories: volatile, decay faster
        cur = conn.execute(
            "UPDATE agent_memories SET decay_rate = 0.990 "
            "WHERE type = 'project' AND decay_rate = 0.995"
        )
        backfill_total += cur.rowcount

        # reference memories: moderately stable
        cur = conn.execute(
            "UPDATE agent_memories SET decay_rate = 0.997 "
            "WHERE type = 'reference' AND decay_rate = 0.995"
        )
        backfill_total += cur.rowcount

        conn.commit()
        conn.close()

        # Build summary
        parts = []
        if added:
            for col in added:
                parts.append(f"Added {col} column.")
        else:
            parts.append("Both columns already present.")

        parts.append(f"Backfilled {backfill_total} rows.")
        print(' '.join(parts))
        sys.exit(0)

    except sqlite3.Error as e:
        print(f"ERROR: Migration failed: {e}", file=sys.stderr)
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: Unexpected error: {e}", file=sys.stderr)
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(1)


if __name__ == '__main__':
    main()
