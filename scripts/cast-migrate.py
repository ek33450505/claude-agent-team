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
    # Canonical schema_migrations shape — identical to the table cast-db-init.sh
    # provisions (the single source of truth). The migration filename is stored in
    # `version`. Previously this used a divergent (id, migration_name) shape, so
    # whichever runner touched the table second errored on INSERT.
    conn.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version    TEXT PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now')),
            checksum   TEXT
        )
    """)
    conn.commit()


def _already_applied(conn: sqlite3.Connection, migration_name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM schema_migrations WHERE version = ?",
        (migration_name,)
    ).fetchone()
    return row is not None


def _record_applied(conn: sqlite3.Connection, migration_name: str) -> None:
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    conn.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at, checksum) VALUES (?, ?, ?)",
        (migration_name, ts, 'py-applied')
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
    """Execute a migration file safely.

    Strategy: run the whole file via executescript (which handles triggers, strings
    containing semicolons, and multi-statement DDL correctly). Idempotency-class errors
    are tolerated on a best-effort basis by falling back to statement-by-statement
    execution when executescript raises a known-safe error class:
    - "duplicate column name" on ALTER TABLE ADD COLUMN (column already added)
    - "no such column" on ALTER TABLE DROP COLUMN (column already dropped)
    - "table … already exists" / "index … already exists" (CREATE IF NOT EXISTS race)
    - "no such table" on ALTER TABLE ADD/DROP COLUMN only — tolerates migrations that
      alter tables owned by cast-db-init.sh (e.g. agent_runs) which don't exist on a
      fresh migrations-only test DB. Any other "no such table" error is re-raised.

    executescript commits any open transaction before running; we rely on that for
    atomicity. The idempotency fallback also commits after each tolerated statement so
    subsequent statements in the same file see the updated schema.
    """
    sql_text = sql_path.read_text(encoding='utf-8')
    try:
        conn.executescript(sql_text)
        # executescript leaves connection in autocommit mode; explicit commit is a no-op
        # but harmless and consistent with the rest of the codebase.
        conn.commit()
        return
    except sqlite3.OperationalError as e:
        err = str(e).lower()
        # If executescript fails with a known idempotency error, fall through to the
        # per-statement path so we can skip just the offending statement.
        # These error classes trigger the per-statement fallback path, where each
        # case is evaluated with the appropriate scope guard (e.g. 'no such table'
        # is only tolerated for ALTER TABLE … ADD COLUMN, not for arbitrary DDL).
        _IDEMPOTENCY_ERRORS = (
            'duplicate column',
            'no such column',
            'already exists',
            'no such table',
        )
        if not any(pat in err for pat in _IDEMPOTENCY_ERRORS):
            raise

    # Per-statement fallback: strip comment-only lines and tolerate known errors.
    statements = [s.strip() for s in sql_text.split(';') if s.strip()]
    for stmt in statements:
        # Strip leading comment lines
        sql_lines = [ln for ln in stmt.splitlines() if not ln.strip().startswith('--')]
        effective = '\n'.join(sql_lines).strip()
        if not effective:
            continue
        try:
            conn.execute(effective)
            conn.commit()
        except sqlite3.OperationalError as e:
            err = str(e).lower()
            stmt_lower = effective.lower()
            if 'duplicate column' in err:
                print(f'  [NOTE] Column already exists (skipping): {effective[:60]}...')
            elif 'no such column' in err and 'drop column' in stmt_lower:
                print(f'  [NOTE] Column already absent (skipping DROP): {effective[:60]}...')
            elif 'already exists' in err:
                print(f'  [NOTE] Object already exists (skipping): {effective[:60]}...')
            elif (
                'no such table' in err
                and 'alter table' in stmt_lower
                and ('add column' in stmt_lower or 'drop column' in stmt_lower)
            ):
                # ALTER TABLE … ADD/DROP COLUMN on a table owned by cast-db-init.sh
                # (e.g. agent_runs — migrations 009 and 014). Table absent on a fresh
                # migrations-only test DB, but the column cannot exist either way,
                # so the intent is already satisfied. Scoped to ALTER TABLE column
                # operations only; other "no such table" errors (e.g. on SELECT,
                # INSERT, CREATE INDEX) are NOT tolerated and will still raise.
                print(f'  [NOTE] Table absent for ALTER COLUMN op (skipping): {effective[:60]}...')
            else:
                raise


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
