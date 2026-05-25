#!/usr/bin/env python3
"""Idempotent migration: create memory_consolidation_runs table in cast.db.

Usage:
    cast-memory-dream-migration.py [--db PATH]

Exit codes:
    0 — success (table created or already exists)
    1 — error (connection failure, schema mismatch)

Output:
    stdout — JSON on success: {"ok": true, "table": "memory_consolidation_runs"}
    stderr — JSON on failure: {"ok": false, "error": "<message>"}
"""

import os
import sys
import json
import sqlite3
import argparse

# cast_db is co-located in scripts/ — guarded import so the migration still
# runs on a broken install where cast_db is unimportable.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from cast_db import log_hook_failure
except Exception:
    log_hook_failure = None


def _maybe_log_failure(*args, **kwargs):
    if log_hook_failure:
        try:
            log_hook_failure(*args, **kwargs)
        except Exception:
            pass


def get_db_path(override=None):
    """Resolve cast.db path — mirrors cast_db.py get_db_path() pattern."""
    if override:
        return override
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


CREATE_SQL = """
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id              TEXT NOT NULL UNIQUE,
    project_id          TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending',
    instructions        TEXT,
    input_fingerprint   TEXT,
    output_path         TEXT,
    error               TEXT,
    started_at          TEXT,
    completed_at        TEXT,
    memory_files_read   INTEGER DEFAULT 0,
    transcripts_scanned INTEGER DEFAULT 0,
    candidates_written  INTEGER DEFAULT 0,
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


def run_migration(db_path):
    """Create the memory_consolidation_runs table idempotently. Returns True on success."""
    conn = sqlite3.connect(db_path, timeout=10)
    try:
        conn.execute(CREATE_SQL)
        conn.commit()
        return True
    except Exception as e:
        raise
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(
        description='Idempotent migration: create memory_consolidation_runs table in cast.db.'
    )
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH env var)')
    args = parser.parse_args()

    db_path = get_db_path(args.db)

    try:
        run_migration(db_path)
        print(json.dumps({"ok": True, "table": "memory_consolidation_runs"}))
        sys.exit(0)
    except Exception as e:
        error_msg = str(e)
        print(json.dumps({"ok": False, "error": error_msg}), file=sys.stderr)
        _maybe_log_failure('cast-memory-dream-migration', 1, error_msg)
        sys.exit(1)


if __name__ == '__main__':
    main()
