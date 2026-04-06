#!/usr/bin/env python3
"""
cast-memory-schema-v4.py — Idempotent schema migration for CAST memory persistence Tier 3.

Creates archived_memories table (identical to agent_memories + archived_at column).
Adds retrieval_count INTEGER DEFAULT 0 column to agent_memories if not present.

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


def get_existing_columns(conn, table_name):
    """Return set of column names for a given table."""
    rows = conn.execute(f"PRAGMA table_info({table_name})").fetchall()
    return {row[1] for row in rows}


def table_exists(conn, table_name):
    """Return True if the table exists."""
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        (table_name,)
    ).fetchone()
    return row is not None


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
        summary_parts = []

        # --- Create archived_memories table ---
        if not table_exists(conn, 'archived_memories'):
            conn.execute("""
                CREATE TABLE IF NOT EXISTS archived_memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent TEXT NOT NULL,
                    project TEXT,
                    type TEXT,
                    name TEXT,
                    description TEXT,
                    content TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    importance REAL DEFAULT 0.5,
                    decay_rate REAL DEFAULT 0.995,
                    embedding BLOB DEFAULT NULL,
                    last_validated_at TIMESTAMP DEFAULT NULL,
                    archived_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            summary_parts.append("Created: archived_memories")
        else:
            summary_parts.append("Already present: archived_memories")

        # --- Add retrieval_count column to agent_memories ---
        existing_cols = get_existing_columns(conn, 'agent_memories')
        if 'retrieval_count' not in existing_cols:
            conn.execute(
                "ALTER TABLE agent_memories ADD COLUMN retrieval_count INTEGER DEFAULT 0"
            )
            summary_parts.append("Added column: retrieval_count")
        else:
            summary_parts.append("Already present: retrieval_count")

        conn.commit()
        conn.close()

        print(". ".join(summary_parts) + ".")
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
