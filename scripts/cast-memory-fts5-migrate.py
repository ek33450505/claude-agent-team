#!/usr/bin/env python3
"""
cast-memory-fts5-migrate.py — Idempotent FTS5 migration for agent_memories table.

Creates the agent_memories_fts virtual table and three sync triggers.
Safe to run multiple times.

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
        # Enable WAL mode
        conn.execute("PRAGMA journal_mode=WAL")

        # Check if FTS table already exists
        existing = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'"
        ).fetchone()

        already_present = existing is not None

        if not already_present:
            # Create FTS5 virtual table
            conn.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(
                    content,
                    description,
                    content='agent_memories',
                    content_rowid='id'
                )
            """)

            # Populate with existing rows
            conn.execute("""
                INSERT INTO agent_memories_fts(rowid, content, description)
                SELECT id, COALESCE(content,''), COALESCE(description,'')
                FROM agent_memories
            """)

        # Create triggers (each is idempotent via IF NOT EXISTS)
        conn.execute("""
            CREATE TRIGGER IF NOT EXISTS am_ai AFTER INSERT ON agent_memories BEGIN
                INSERT INTO agent_memories_fts(rowid, content, description)
                VALUES (new.id, COALESCE(new.content,''), COALESCE(new.description,''));
            END
        """)

        conn.execute("""
            CREATE TRIGGER IF NOT EXISTS am_au AFTER UPDATE ON agent_memories BEGIN
                INSERT INTO agent_memories_fts(agent_memories_fts, rowid, content, description)
                VALUES('delete', old.id, COALESCE(old.content,''), COALESCE(old.description,''));
                INSERT INTO agent_memories_fts(rowid, content, description)
                VALUES (new.id, COALESCE(new.content,''), COALESCE(new.description,''));
            END
        """)

        conn.execute("""
            CREATE TRIGGER IF NOT EXISTS am_ad AFTER DELETE ON agent_memories BEGIN
                INSERT INTO agent_memories_fts(agent_memories_fts, rowid, content, description)
                VALUES('delete', old.id, COALESCE(old.content,''), COALESCE(old.description,''));
            END
        """)

        conn.commit()

        # Count indexed rows
        row_count = conn.execute("SELECT COUNT(*) FROM agent_memories_fts").fetchone()[0]

        if already_present:
            print(f"FTS5 already present. {row_count} rows indexed. Triggers verified.")
        else:
            print(f"FTS5 migration complete. {row_count} rows indexed.")

        conn.close()
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
