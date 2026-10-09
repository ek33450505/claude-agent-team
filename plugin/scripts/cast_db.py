#!/usr/bin/env python3
"""CAST database abstraction layer. Reads CAST_DB_URL env var, defaults to ~/.claude/cast.db."""
import os
import re
import sqlite3
import datetime
import unicodedata
from pathlib import Path

# All tables that cast_db.py is allowed to write to.
ALLOWED_TABLES = {
    'ack_events',
    'agent_hallucinations',
    'agent_memories',
    'agent_protocol_violations',
    'agent_runs',
    'agent_truncations',
    'budgets',
    # 'code_ref_checks' — RETIRED v9 Phase C U7b (writer purged in v9 S5; 0 rows)
    'commit_provenance',
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
    'provenance_chain',
    'quality_gates',
    'rate_limit_snapshots',
    'routines',
    'routing_events',
    'schema_migrations',
    'sessions',
    'stop_failure_events',
    'tool_call_failures',
    'swarm_sessions',
    'task_queue',
    'managed_agent_invocations',
    'teammate_runs',
    'worktree_anomalies',
    'eval_runs',
}

# Allowlist for CAST_DB_URL / CAST_DB_PATH resolved paths.
# Goal: block traversals into /etc, /usr, /root, other users' homes — while
# allowing the user's ~/.claude/ and the system temp roots used by BATS / pytest.
# The prefixes are CONSTANTS plus ~/.claude. They are deliberately NOT derived from
# TMPDIR/TMP/TEMP/BATS_* or tempfile.gettempdir() (which honours TMPDIR): those are
# caller-steerable, and TMPDIR=$HOME (or a symlink to it) would admit every path under
# $HOME. An env-derived temp dir that lies under one of these roots adds nothing (it is
# already covered); one that lies elsewhere must NOT be admitted.
_STATIC_TEMP_ROOTS = ('/tmp', '/private/tmp', '/var/folders', '/private/var/folders')

# ~/.claude is NOT allowed as a whole: it holds code/config CAST executes or trusts
# (scripts/, config/, settings*.json, install-manifest.sha256, venv/, ...), and a DB (plus its
# -wal/-shm/-journal siblings) created there squats the name and breaks the reader. Inside
# ~/.claude only a POSITIVE allowlist is admitted: a DIRECT child whose name ends in '.db'
# (cast.db, cast-test.db, ...) and does not start with 'settings'. Repo-wide grep shows no real
# CAST DB in any ~/.claude subdirectory (backups go to ~/Library/Application Support/cast),
# so no subdirectory is admitted. Compared case-insensitively and NFC-normalised, because the
# default macOS filesystem is case-insensitive (Scripts/ and scripts/ are the same directory).
_CLAUDE_DB_SUFFIX = '.db'
_CLAUDE_DB_DENY_PREFIXES = ('settings',)


def _fold(path: str) -> str:
    text = unicodedata.normalize('NFC', os.path.normcase(path))
    return unicodedata.normalize('NFC', text.casefold())


def _claude_db_refusal(resolved: str) -> str:
    """'' when `resolved` is outside ~/.claude or an allowed DB location inside it; otherwise
    the reason it is refused. Both the literal and the resolved spelling of ~/.claude count
    HERE, but note the later allowlist step (`_allowed_db_prefixes`) admits only the LITERAL
    ~/.claude prefix: under a symlinked ~/.claude only the default cast.db (via the resolved
    default fallback in `_get_db_path`) is accepted."""
    home_claude = Path.home() / '.claude'
    target = _fold(resolved)
    for base in {str(home_claude), os.path.realpath(home_claude)}:
        fbase = _fold(base)
        if target == fbase:
            return 'is ~/.claude itself'
        if not target.startswith(fbase + os.sep):
            continue
        rel = target[len(fbase) + 1:]
        if os.sep in rel:
            return 'is inside a ~/.claude subdirectory'
        if (not rel.endswith(_CLAUDE_DB_SUFFIX) or len(rel) <= len(_CLAUDE_DB_SUFFIX)
                or rel.startswith(_CLAUDE_DB_DENY_PREFIXES)):
            return 'is not a *.db file directly under ~/.claude'
        return ''
    return ''


def _allowed_db_prefixes() -> tuple:
    prefixes = [str(Path.home() / '.claude') + os.sep]
    for root in _STATIC_TEMP_ROOTS:
        # the literal root and its realpath (macOS: /tmp -> /private/tmp; Linux: identity)
        for form in (root, os.path.realpath(root)):
            prefix = form + os.sep
            if prefix not in prefixes:
                prefixes.append(prefix)
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
    reason = _claude_db_refusal(resolved)
    if reason:
        raise ValueError(f'CAST_DB_URL/CAST_DB_PATH {reason}: {resolved!r}.')
    prefixes = _allowed_db_prefixes()
    if not any(resolved.startswith(prefix) for prefix in prefixes):
        # Also accept exact match against the default db file (no trailing sep needed)
        default = str((Path.home() / '.claude' / 'cast.db').resolve())
        if resolved != default:
            raise ValueError(
                f'CAST_DB_URL/CAST_DB_PATH resolves to an unexpected path: {resolved!r}. '
                f'Must be under {prefixes}.'
            )
    # Connect to what was checked, not to the unresolved spelling (symlink/.. swaps)
    return resolved


def _connect():
    db_path = _get_db_path()
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    # Harden against lock contention and ensure WAL mode (idempotent if already WAL).
    # Never raise — a PRAGMA failure must not crash the hook pipeline.
    try:
        conn.execute('PRAGMA busy_timeout=5000;')
        conn.execute('PRAGMA journal_mode=WAL;')
        conn.execute('PRAGMA synchronous=NORMAL;')
    except Exception as e:
        _log_error(f'_connect PRAGMA setup failed (non-fatal): {e}')
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


_LOG_MSG_MAX = 2000


def _is_log_control(c: str) -> bool:
    """C0, DEL, C1, line/paragraph separators, bidi controls (U+202A-202E, U+2066-2069 and the
    marks U+200E/200F/061C), zero-width/format characters (U+200B-200D, U+2060-2064,
    U+206A-206F, U+180E, U+FEFF): invisible or
    reordering characters that can disguise a forged log line."""
    o = ord(c)
    return (o < 32 or 0x7f <= o <= 0x9f
            or o in (0x2028, 0x2029, 0x200e, 0x200f, 0x061c, 0xfeff, 0x180e)
            or 0x200b <= o <= 0x200d or 0x202a <= o <= 0x202e
            or 0x2060 <= o <= 0x2064 or 0x2066 <= o <= 0x2069 or 0x206a <= o <= 0x206f)


def _sanitize_log_msg(msg) -> str:
    """One log line, no injection: CR/LF are escaped, every other control character (C0, DEL,
    C1, separators, bidi and zero-width characters) becomes a space, and the result is
    capped. Error text can embed attacker-influenced content (e.g. a trigger's RAISE
    message), and the log is a line-oriented file."""
    text = str(msg).replace('\r', '\\r').replace('\n', '\\n')
    text = ''.join(' ' if _is_log_control(c) else c for c in text)
    if len(text) > _LOG_MSG_MAX:
        text = text[:_LOG_MSG_MAX] + '...[truncated]'
    return text


def _log_error(msg: str) -> None:
    # NOTE: CAST_DB_PATH / CAST_DB_URL do NOT redirect this log - it always goes to
    # ~/.claude/logs. A redirect beside the DB was an arbitrary-file-append primitive
    # (hardlinks/symlink races); tests and tools must isolate HOME instead.
    # Never raises (Path.home() is inside the try; the fallback is stderr).
    try:
        safe = _sanitize_log_msg(msg)
    except Exception:
        safe = '<unprintable message>'
    try:
        log_path = Path.home() / '.claude' / 'logs' / 'db-write-errors.log'
        log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
        with open(log_path, 'a') as f:
            f.write(f'[{ts}] ERROR cast_db.py: {safe}\n')
    except Exception:
        import sys
        try:
            sys.stderr.write(f'cast_db.py ERROR (log unavailable): {safe}\n')
        except Exception:
            pass


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
            'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
        })
    except Exception as e:
        import sys
        print(f'[hook_failures] DB write failed (non-fatal): {e}', file=sys.stderr)
