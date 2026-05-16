#!/usr/bin/env python3
"""CAST migration runner — applies versioned SQL migrations to cast.db idempotently.

Usage:
    python3 scripts/cast-migrate.py [--dry-run]

Migrations live in scripts/migrations/NNN_name.sql and are applied in numeric order.
A schema_migrations table tracks applied migrations. Safe to run multiple times.
"""
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


def _get_db_path() -> str:
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return str(Path(os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))))


def _connect(db_path: str) -> sqlite3.Connection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def _ensure_migrations_table(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            migration_name TEXT UNIQUE NOT NULL,
            applied_at     TEXT NOT NULL
        )
    """)
    conn.commit()


def _already_applied(conn: sqlite3.Connection, migration_name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM schema_migrations WHERE migration_name = ?",
        (migration_name,)
    ).fetchone()
    return row is not None


def _record_applied(conn: sqlite3.Connection, migration_name: str) -> None:
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    conn.execute(
        "INSERT OR IGNORE INTO schema_migrations (migration_name, applied_at) VALUES (?, ?)",
        (migration_name, ts)
    )
    conn.commit()


def _find_migrations(migrations_dir: Path) -> list:
    """Return sorted list of (number, filename, path) for all NNN_*.sql files."""
    results = []
    if not migrations_dir.exists():
        return results
    pattern = re.compile(r'^(\d+)_.+\.sql$')
    for p in sorted(migrations_dir.iterdir()):
        m = pattern.match(p.name)
        if m and not p.is_symlink():
            results.append((int(m.group(1)), p.name, p))
    results.sort(key=lambda x: x[0])
    return results


def _apply_migration(conn: sqlite3.Connection, sql_path: Path) -> None:
    """Execute all statements in the SQL file. Idempotency-class errors are tolerated:
    - "duplicate column name" on ALTER TABLE ADD COLUMN (column already added)
    - "no such column" on ALTER TABLE DROP COLUMN (column already dropped or never existed)
    """
    sql_text = sql_path.read_text(encoding='utf-8')
    # Split on semicolons but keep non-empty statements
    statements = [s.strip() for s in sql_text.split(';') if s.strip()]
    for stmt in statements:
        if not stmt:
            continue
        # Strip leading comment lines to get the actual SQL
        sql_lines = [ln for ln in stmt.splitlines() if not ln.strip().startswith('--')]
        effective = '\n'.join(sql_lines).strip()
        if not effective:
            continue
        stmt = effective
        try:
            conn.execute(stmt)
        except sqlite3.OperationalError as e:
            err = str(e).lower()
            # Tolerate "duplicate column name" from ALTER TABLE ADD COLUMN (idempotency)
            if 'duplicate column' in err:
                print(f'  [NOTE] Column already exists (skipping): {stmt[:60]}...')
            # Tolerate "no such column" from ALTER TABLE DROP COLUMN (already-dropped idempotency)
            elif 'no such column' in err and 'drop column' in stmt.lower():
                print(f'  [NOTE] Column already absent (skipping DROP): {stmt[:60]}...')
            else:
                raise
    conn.commit()


def main() -> int:
    dry_run = '--dry-run' in sys.argv

    db_path = _get_db_path()
    # Resolve migrations dir relative to this script's location
    script_dir = Path(__file__).resolve().parent
    migrations_dir = script_dir / 'migrations'

    migrations = _find_migrations(migrations_dir)
    if not migrations:
        print('[cast-migrate] No migration files found in', migrations_dir)
        return 0

    conn = _connect(db_path)
    _ensure_migrations_table(conn)

    pending = []
    skipped = []
    for _num, name, path in migrations:
        if _already_applied(conn, name):
            skipped.append(name)
        else:
            pending.append((name, path))

    if dry_run:
        print(f'[cast-migrate] Dry run against {db_path}')
        for name, _ in pending:
            print(f'  [PENDING] {name}')
        for name in skipped:
            print(f'  [SKIPPED] {name} (already applied)')
        print(f'[cast-migrate] {len(pending)} pending, {len(skipped)} already applied')
        conn.close()
        return 0

    for name, path in pending:
        print(f'  [APPLYING] {name}')
        try:
            _apply_migration(conn, path)
            _record_applied(conn, name)
            print(f'  [APPLIED]  {name}')
        except Exception as e:
            print(f'  [ERROR]    {name}: {e}', file=sys.stderr)
            conn.close()
            return 1

    for name in skipped:
        print(f'  [SKIPPED]  {name} (already applied)')

    print(f'[cast-migrate] Done: {len(pending)} applied, {len(skipped)} skipped')
    conn.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
