#!/usr/bin/env python3
"""
cast-memory-schema-v3.py — Idempotent schema migration for agent_memories.

Adds embedding BLOB DEFAULT NULL and last_validated_at TIMESTAMP DEFAULT NULL
columns if not present.

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
        existing_cols = get_existing_columns(conn)

        added = []
        already_present = []

        if 'embedding' not in existing_cols:
            conn.execute("ALTER TABLE agent_memories ADD COLUMN embedding BLOB DEFAULT NULL")
            added.append('embedding')
        else:
            already_present.append('embedding')

        if 'last_validated_at' not in existing_cols:
            conn.execute("ALTER TABLE agent_memories ADD COLUMN last_validated_at TIMESTAMP DEFAULT NULL")
            added.append('last_validated_at')
        else:
            already_present.append('last_validated_at')

        conn.commit()
        conn.close()

        if added and not already_present:
            print(f"Added: {', '.join(added)}.")
        elif already_present and not added:
            print("Both columns already present.")
        elif added and already_present:
            print(f"Added: {', '.join(added)}. Already present: {', '.join(already_present)}.")
        else:
            print("Both columns already present.")

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
