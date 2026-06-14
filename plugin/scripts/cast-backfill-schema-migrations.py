#!/usr/bin/env python3
"""One-time backfill: insert missing schema_migrations rows for migration files
that exist in scripts/migrations/ but aren't recorded.

Live schema: (version TEXT PK, applied_at TEXT, checksum TEXT)
Idempotent: INSERT OR IGNORE on PK (version column).

The live schema_migrations table is created by cast-migrate.py and cast-db-init.sh.
Schema: (version TEXT PK, applied_at TEXT, checksum TEXT).
cast-migrate.sh has been removed; cast-migrate.py is now the single runner.

Usage:
  python3 cast-backfill-schema-migrations.py [--db PATH] [--dry-run]
"""

import argparse
import hashlib
import os
import sqlite3
import subprocess
import sys
from pathlib import Path


def get_db_path() -> str:
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def git_first_commit_date(file_path: Path, repo_root: Path) -> str | None:
    """Return the ISO 8601 date of the first git commit that introduced this file."""
    try:
        result = subprocess.check_output(
            ['git', 'log', '--diff-filter=A', '--format=%aI', '--', str(file_path)],
            cwd=str(repo_root),
            stderr=subprocess.DEVNULL,
        ).decode().strip().splitlines()
        # --format=%aI lists most-recent first; last entry = original add
        return result[-1] if result else None
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Backfill schema_migrations for migration files not yet recorded.'
    )
    parser.add_argument('--db', default=None, help='Path to cast.db (default: CAST_DB_PATH env or ~/.claude/cast.db)')
    parser.add_argument('--dry-run', action='store_true', help='Print what would be inserted without writing')
    args = parser.parse_args()

    db_path = args.db or get_db_path()

    # Resolve repo root from this script's location (scripts/ lives one level below repo root)
    repo_root = Path(__file__).resolve().parent.parent
    migrations_dir = repo_root / 'scripts' / 'migrations'

    if not migrations_dir.is_dir():
        print(f'ERROR: migrations dir not found at {migrations_dir}', file=sys.stderr)
        return 1

    if not os.path.exists(db_path):
        print(f'ERROR: cast.db not found at {db_path}', file=sys.stderr)
        return 1

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except Exception as e:
        print(f'ERROR: could not connect to {db_path}: {e}', file=sys.stderr)
        return 1

    try:
        # Fetch already-recorded versions
        existing = {row[0] for row in conn.execute('SELECT version FROM schema_migrations')}
    except sqlite3.OperationalError as e:
        print(f'ERROR: schema_migrations table not found or inaccessible: {e}', file=sys.stderr)
        conn.close()
        return 1

    inserted = 0
    skipped = 0
    for mig_file in sorted(migrations_dir.glob('*.sql')):
        # version = filename stem (e.g. "009_cast_framework_fixes")
        version = mig_file.stem

        if version in existing:
            skipped += 1
            continue

        body = mig_file.read_bytes()
        checksum = hashlib.sha256(body).hexdigest()
        applied_at = git_first_commit_date(mig_file, repo_root) or 'unknown'

        if args.dry_run:
            print(f'[DRY] would insert: {version} | applied_at={applied_at} | checksum={checksum[:16]}...')
        else:
            conn.execute(
                'INSERT OR IGNORE INTO schema_migrations (version, applied_at, checksum) VALUES (?, ?, ?)',
                (version, applied_at, checksum),
            )
            inserted += 1
            print(f'Inserted: {version} | applied_at={applied_at}')

    if not args.dry_run:
        conn.commit()

    conn.close()

    if args.dry_run:
        print(f'Dry run complete — {skipped} already recorded, would insert {len(list(migrations_dir.glob("*.sql"))) - skipped} rows.')
    else:
        print(f'Done — inserted {inserted} rows ({skipped} already recorded).')

    return 0


if __name__ == '__main__':
    sys.exit(main())
