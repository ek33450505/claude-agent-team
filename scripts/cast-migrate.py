#!/usr/bin/env python3
"""CAST migration runner — applies versioned SQL migrations to cast.db idempotently.

Usage:
    python3 scripts/cast-migrate.py [--dry-run]   # default: list pending, no DB changes
    python3 scripts/cast-migrate.py --confirm      # actually apply pending migrations
    python3 scripts/cast-migrate.py --dry-run      # explicit read-only listing

Migrations live in scripts/migrations/NNN_name.sql and are applied in numeric order.
A schema_migrations table tracks applied migrations. Safe to run multiple times.

Flags are mutually exclusive. Any unrecognised argument is an error (exit 2).
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
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

    # Per-statement fallback: strip -- line comments before splitting on ';' so that
    # semicolons inside comments (e.g. migration 022: "guarantees run-once; no guard
    # needed here") don't produce spurious invalid statement fragments.
    comment_free = '\n'.join(
        line for line in sql_text.splitlines()
        if not line.strip().startswith('--')
    )
    statements = [s.strip() for s in comment_free.split(';') if s.strip()]
    for stmt in statements:
        effective = stmt
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
            elif 'no such column' in err and stmt_lower.lstrip().startswith('create index'):
                # CREATE INDEX on a column owned by cast-db-init.sh that a legacy/
                # narrow agent_runs (or similar) fixture predates (e.g. migration
                # 031's idx_agent_runs_started_at on a pre-started_at agent_runs
                # shape). Column absent on that narrow schema, but the intent
                # (indexing it, once present) is not applicable — skip rather than
                # fail the whole migration file. Scoped strictly to CREATE INDEX.
                print(f'  [NOTE] Column absent for CREATE INDEX (skipping): {effective[:60]}...')
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
            elif (
                'no such table' in err
                and (stmt_lower.lstrip().startswith('update ')
                     or stmt_lower.lstrip().startswith('delete '))
            ):
                # UPDATE/DELETE on a table owned by cast-db-init.sh (e.g.
                # migrations 020/021 touch agent_runs/sessions). On a
                # migrations-only test DB those tables don't exist yet, but the
                # intent is already satisfied: zero rows to mutate = no-op.
                # Scoped strictly to UPDATE and DELETE — SELECT, INSERT, CREATE
                # INDEX, and DDL errors are NOT tolerated and will still raise.
                print(f'  [NOTE] Table absent for UPDATE/DELETE op (skipping): {effective[:60]}...')
            else:
                raise


def _pre_migration_backup(db_path: str) -> int:
    """Run cast-db-backup.py before applying any migration.

    Fatal gate: if the backup subprocess exits non-zero, times out, or cannot
    be invoked, print a clear error to stderr and return 1.  The caller must
    abort the migration run before touching the database.

    On success, print a one-line confirmation and return 0.
    """
    script_dir = Path(__file__).resolve().parent
    backup_script = script_dir / 'cast-db-backup.py'

    if not backup_script.exists():
        print(
            f'[cast-migrate] ERROR: Pre-migration backup script not found: {backup_script}',
            file=sys.stderr,
        )
        return 1

    try:
        result = subprocess.run(
            [sys.executable, str(backup_script)],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        print(
            '[cast-migrate] ERROR: Pre-migration backup timed out after 120s — aborting.',
            file=sys.stderr,
        )
        return 1
    except Exception as e:
        print(
            f'[cast-migrate] ERROR: Pre-migration backup invocation failed: {e}',
            file=sys.stderr,
        )
        return 1

    if result.returncode != 0:
        raw = result.stdout.strip()
        error_detail = ''
        if raw:
            try:
                payload = json.loads(raw)
                error_detail = payload.get('error', raw)
            except json.JSONDecodeError:
                error_detail = raw
        if not error_detail and result.stderr.strip():
            error_detail = result.stderr.strip()
        print(
            f'[cast-migrate] ERROR: Pre-migration backup failed: {error_detail}',
            file=sys.stderr,
        )
        return 1

    raw = result.stdout.strip()
    try:
        payload = json.loads(raw)
        backup_path = payload.get('backup_path', '(unknown)')
    except json.JSONDecodeError:
        backup_path = '(unparseable output)'

    print(f'[cast-migrate] Pre-migration backup: {backup_path}')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog='cast-migrate',
        description='Apply versioned SQL migrations to cast.db idempotently.',
        epilog=(
            'Migrations live in scripts/migrations/NNN_name.sql and are applied in '
            'numeric order. Safe to run multiple times — already-applied migrations are '
            'skipped. Default (no flags) performs a dry run; pass --confirm to apply.'
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        '--dry-run',
        action='store_true',
        help='Show pending migrations without applying them (read-only, default).',
    )
    mode.add_argument(
        '--confirm',
        action='store_true',
        help='Actually apply pending migrations to the database.',
    )
    args = parser.parse_args()
    # Dry-run is the default when neither flag is passed.
    dry_run = not args.confirm

    db_path = _get_db_path()
    # Resolve migrations dir relative to this script's location
    script_dir = Path(__file__).resolve().parent
    migrations_dir = script_dir / 'migrations'

    migrations = _find_migrations(migrations_dir)
    if not migrations:
        print('[cast-migrate] No migration files found in', migrations_dir)
        return 0

    conn = _connect(db_path)

    if dry_run:
        # READ-ONLY path: do NOT call _ensure_migrations_table — that would
        # create schema_migrations even on an un-initialised DB. Instead,
        # query the ledger if it already exists, else treat all as pending.
        try:
            rows = conn.execute("SELECT version FROM schema_migrations").fetchall()
            applied_set = {row[0] for row in rows}
        except sqlite3.OperationalError:
            applied_set = set()

        pending = []
        skipped = []
        for _num, name, _path in migrations:
            if name in applied_set:
                skipped.append(name)
            else:
                pending.append(name)

        print(f'[cast-migrate] Dry run against {db_path}')
        for name in pending:
            print(f'  [PENDING] {name}')
        for name in skipped:
            print(f'  [SKIPPED] {name} (already applied)')
        print(f'[cast-migrate] {len(pending)} pending, {len(skipped)} already applied')
        if not args.dry_run:
            # Hint only when we defaulted to dry-run (no explicit flag given).
            print('[cast-migrate] Dry run by default — pass --confirm to apply.')
        conn.close()
        return 0

    _ensure_migrations_table(conn)

    pending = []
    skipped = []
    for _num, name, path in migrations:
        if _already_applied(conn, name):
            skipped.append(name)
        else:
            pending.append((name, path))

    if pending:
        rc = _pre_migration_backup(db_path)
        if rc != 0:
            conn.close()
            return 1

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
