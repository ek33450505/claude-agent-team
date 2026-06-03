#!/usr/bin/env python3
"""CAST database abstraction layer. Reads CAST_DB_URL env var, defaults to ~/.claude/cast.db."""
import os
import re
import sqlite3
import datetime
import tempfile
from pathlib import Path

# All tables that cast_db.py is allowed to write to.
ALLOWED_TABLES = {
    'agent_hallucinations',
    'agent_memories',
    'agent_protocol_violations',
    'agent_runs',
    'agent_truncations',
    'budgets',
    'code_ref_checks',
    'compaction_events',
    'completeness_events',
    'dispatch_decisions',
    'dispatch_events',
    'file_writes',
    'hook_failures',
    'incidents',
    'injection_log',
    'pane_bindings',
    'parry_guard_events',
    'memory_consolidation_runs',
    'plan_sessions',
    'quality_gates',
    'rate_limit_snapshots',
    'routines',
    'routing_events',
    'schema_migrations',
    'sessions',
    'stop_failure_events',
    'stream_events',
    'tool_call_failures',
    'swarm_sessions',
    'task_queue',
    'teammate_messages',
    'teammate_runs',
    'unstaged_warnings',
    'worktree_anomalies',
}

# Allowlist for CAST_DB_URL / CAST_DB_PATH resolved paths.
# Goal: block traversals into /etc, /usr, /root, other users' homes — while
# allowing the user's ~/.claude/ and any system tempdir used by BATS / pytest.
# The allowlist is evaluated per-call (not cached at module level) so it reflects
# current env vars (e.g. TMPDIR, BATS_TMPDIR) at the time of each DB access.
def _allowed_db_prefixes() -> tuple:
    prefixes = [
        str(Path.home() / '.claude') + os.sep,
        '/tmp/',
        str(Path('/tmp').resolve()) + os.sep,
        str(Path(tempfile.gettempdir()).resolve()) + os.sep,
        # macOS system temp: /var/folders/... resolves to /private/var/folders/...
        '/var/folders/',
        str(Path('/var/folders').resolve()) + os.sep,
    ]
    # Include any temp-dir env vars (TMPDIR, TEMP, TMP) — handles macOS mktemp paths
    for env_var in ('TMPDIR', 'TEMP', 'TMP'):
        val = os.environ.get(env_var)
        if val:
            prefixes.append(str(Path(val).resolve()) + os.sep)
    bats_tmpdir = os.environ.get('BATS_TEST_TMPDIR') or os.environ.get('BATS_TMPDIR')
    if bats_tmpdir:
        prefixes.append(str(Path(bats_tmpdir).resolve()) + os.sep)
    return tuple(prefixes)


def _validate_identifier(name: str) -> str:
    """Validate that name is a safe SQL identifier (table or column name).

    Raises ValueError if name contains characters outside [a-zA-Z0-9_] or
    does not start with a letter or underscore.
    """
    if not re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', name):
        raise ValueError(f'Invalid SQL identifier: {name!r}')
    return name


def _get_db_path() -> str:
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        raw = url[len('sqlite:///'):]
    else:
        raw = str(Path(os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))))
    resolved = str(Path(raw).resolve())
    prefixes = _allowed_db_prefixes()
    if not any(resolved.startswith(prefix) for prefix in prefixes):
        # Also accept exact match against the default db file (no trailing sep needed)
        default = str((Path.home() / '.claude' / 'cast.db').resolve())
        if resolved != default:
            raise ValueError(
                f'CAST_DB_URL/CAST_DB_PATH resolves to an unexpected path: {resolved!r}. '
                f'Must be under {prefixes}.'
            )
    return raw


def _connect():
    db_path = _get_db_path()
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def db_write(table: str, payload: dict) -> bool:
    """Insert a row into table using INSERT OR REPLACE. Keys become columns.

    Returns True on success, False on any failure. Never raises. Callers that
    ignore the return value are unaffected — the never-raise contract is preserved.
    Retries up to 3 times on 'locked' OperationalError before returning False.
    """
    _validate_identifier(table)
    if table not in ALLOWED_TABLES:
        raise ValueError(f'Table {table!r} is not in the CAST allowed-tables list.')
    for col in payload.keys():
        _validate_identifier(col)
    cols = ', '.join(payload.keys())
    placeholders = ', '.join(['?' for _ in payload])
    sql = f'INSERT OR REPLACE INTO {table} ({cols}) VALUES ({placeholders})'
    for attempt in range(3):
        try:
            with _connect() as conn:
                conn.execute(sql, list(payload.values()))
                conn.commit()
            return True
        except sqlite3.OperationalError as e:
            if 'locked' in str(e) and attempt < 2:
                import time
                time.sleep(0.1 * (attempt + 1))
            else:
                _log_error(f'db_write failed on {table}: {e}')
                return False
        except Exception as e:
            _log_error(f'db_write failed on {table}: {e}')
            return False


def db_query(sql: str, params: tuple = ()) -> list:
    """Run a SELECT and return list of Row objects."""
    try:
        with _connect() as conn:
            return conn.execute(sql, params).fetchall()
    except Exception as e:
        _log_error(f'db_query failed: {e}')
        return []


def db_execute(sql: str, params: tuple = ()) -> bool:
    """Run a non-SELECT statement (INSERT/UPDATE/DELETE/PRAGMA).

    Returns True on success, False on any failure. Never raises. Callers that
    ignore the return value are unaffected — the never-raise contract is preserved.
    Retries up to 3 times on 'locked' OperationalError before returning False.
    """
    for attempt in range(3):
        try:
            with _connect() as conn:
                conn.execute(sql, params)
                conn.commit()
            return True
        except sqlite3.OperationalError as e:
            if 'locked' in str(e) and attempt < 2:
                import time
                time.sleep(0.1 * (attempt + 1))
            else:
                _log_error(f'db_execute failed: {e}')
                return False
        except Exception as e:
            _log_error(f'db_execute failed: {e}')
            return False


def _log_error(msg: str) -> None:
    try:
        log_path = Path.home() / '.claude' / 'logs' / 'db-write-errors.log'
        log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.datetime.utcnow().isoformat() + 'Z'
        with open(log_path, 'a') as f:
            f.write(f'[{ts}] ERROR cast_db.py: {msg}\n')
    except Exception:
        import sys
        sys.stderr.write(f'cast_db.py ERROR (log unavailable): {msg}\n')


def ensure_schema_columns() -> None:
    """Idempotently add new columns introduced in Phase 1 hygiene.

    Uses ALTER TABLE with try/except so repeated runs are safe.
    Called at module import time in scripts that need these columns.
    """
    migrations = [
        ("ALTER TABLE sessions ADD COLUMN status TEXT DEFAULT 'ended'", "sessions.status"),
        ("ALTER TABLE dispatch_decisions ADD COLUMN outcome TEXT DEFAULT 'pending'", "dispatch_decisions.outcome"),
        ("ALTER TABLE agent_memories ADD COLUMN last_validated_at TEXT", "agent_memories.last_validated_at"),
        ("ALTER TABLE agent_memories ADD COLUMN retrieval_count INTEGER DEFAULT 0", "agent_memories.retrieval_count"),
    ]
    for sql, label in migrations:
        try:
            db_execute(sql)
        except Exception as e:
            # Column already exists — that's fine. Any other error is also non-fatal.
            if 'duplicate column' not in str(e).lower() and 'already exists' not in str(e).lower():
                _log_error(f'ensure_schema_columns: {label}: {e}')


def ensure_hook_failures_table() -> None:
    """Idempotently create the hook_failures table if it does not exist."""
    sql = """CREATE TABLE IF NOT EXISTS hook_failures (
        id         TEXT PRIMARY KEY,
        hook_name  TEXT NOT NULL,
        exit_code  INTEGER,
        stderr     TEXT,
        session_id TEXT,
        timestamp  TEXT NOT NULL
    )"""
    db_execute(sql)


def ensure_tool_call_failures_table() -> None:
    """Idempotently create the tool_call_failures table if it does not exist."""
    sql = """CREATE TABLE IF NOT EXISTS tool_call_failures (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp  TEXT    NOT NULL,
        session_id TEXT,
        tool_name  TEXT    NOT NULL,
        error      TEXT,
        project    TEXT,
        data       TEXT
    )"""
    db_execute(sql)


def log_hook_failure(hook_name: str, exit_code: int, stderr: str, session_id: str = None) -> None:
    """Write a row to hook_failures. Wraps the DB write in try/except — MUST NOT crash the hook pipeline.

    Call this from hook error handlers in place of (or in addition to) plain file logging.
    Falls back to stderr-only if the DB write fails for any reason.
    """
    import uuid
    try:
        ensure_hook_failures_table()
        db_write('hook_failures', {
            'id': str(uuid.uuid4()),
            'hook_name': hook_name,
            'exit_code': exit_code,
            'stderr': (stderr or '')[:2000],
            'session_id': session_id,
            'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
        })
    except Exception as e:
        import sys
        print(f'[hook_failures] DB write failed (non-fatal): {e}', file=sys.stderr)
