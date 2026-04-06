#!/usr/bin/env python3
"""
cast-db-backup.py — WAL-safe SQLite backup for cast.db

Uses Python's sqlite3.backup() API for a consistent, WAL-safe database
snapshot. Complements cast-memory-backup.sh (tar + GitHub release backup).

Behavior:
  1. Connect to ~/.claude/cast.db (or CAST_DB_PATH env override)
  2. Create backup at ~/.claude/backups/cast-db-YYYY-MM-DD.db
  3. Enforce retention: keep 7 daily backups, delete older ones
  4. Print JSON status report

Exit codes: 0=success, 1=error
"""
import sqlite3
import os
import sys
import json
import glob
from datetime import datetime, timedelta
from pathlib import Path


def get_db_path():
    """Resolve cast.db path from env or default."""
    return os.path.expanduser(
        os.environ.get('CAST_DB_PATH', '~/.claude/cast.db')
    )


def get_backup_dir():
    """Resolve backup directory."""
    return os.path.expanduser('~/.claude/backups')


def create_backup(db_path, backup_dir):
    """Perform WAL-safe backup using sqlite3.backup() API."""
    today = datetime.now().strftime('%Y-%m-%d')
    backup_path = os.path.join(backup_dir, f'cast-db-{today}.db')

    # Create backup directory if needed
    os.makedirs(backup_dir, exist_ok=True)

    # Connect to source database
    src = sqlite3.connect(db_path)
    dst = sqlite3.connect(backup_path)

    try:
        src.backup(dst)
        dst.close()
        src.close()
    except Exception as e:
        dst.close()
        src.close()
        # Clean up partial backup
        if os.path.exists(backup_path):
            os.remove(backup_path)
        raise e

    return backup_path


def enforce_retention(backup_dir, keep_days=7):
    """Keep only the most recent `keep_days` backups, delete older ones."""
    pattern = os.path.join(backup_dir, 'cast-db-*.db')
    backups = sorted(glob.glob(pattern))

    pruned = 0
    if len(backups) > keep_days:
        to_remove = backups[:len(backups) - keep_days]
        for old_backup in to_remove:
            try:
                os.remove(old_backup)
                pruned += 1
            except OSError:
                pass

    retained = len(backups) - pruned
    return retained, pruned


def main():
    db_path = get_db_path()
    backup_dir = get_backup_dir()

    # Verify source database exists
    if not os.path.exists(db_path):
        print(json.dumps({
            'error': f'Source database not found: {db_path}',
            'backup_path': None,
            'size_bytes': 0,
            'retained': 0,
            'pruned': 0
        }))
        sys.exit(1)

    try:
        # Perform backup
        backup_path = create_backup(db_path, backup_dir)
        size_bytes = os.path.getsize(backup_path)

        # Enforce retention
        retained, pruned = enforce_retention(backup_dir)

        result = {
            'backup_path': backup_path,
            'size_bytes': size_bytes,
            'retained': retained,
            'pruned': pruned
        }
        print(json.dumps(result))
        sys.exit(0)

    except Exception as e:
        print(json.dumps({
            'error': str(e),
            'backup_path': None,
            'size_bytes': 0,
            'retained': 0,
            'pruned': 0
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
