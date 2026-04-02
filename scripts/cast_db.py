#!/usr/bin/env python3
"""CAST database abstraction layer. Reads CAST_DB_URL env var, defaults to ~/.claude/cast.db."""
import os
import sqlite3
import datetime
from pathlib import Path


def _get_db_path() -> str:
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return str(Path(os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))))


def _connect():
    db_path = _get_db_path()
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def db_write(table: str, payload: dict) -> None:
    """Insert a row into table using INSERT OR REPLACE. Keys become columns."""
    cols = ', '.join(payload.keys())
    placeholders = ', '.join(['?' for _ in payload])
    sql = f'INSERT OR REPLACE INTO {table} ({cols}) VALUES ({placeholders})'
    for attempt in range(3):
        try:
            with _connect() as conn:
                conn.execute(sql, list(payload.values()))
                conn.commit()
            return
        except sqlite3.OperationalError as e:
            if 'locked' in str(e) and attempt < 2:
                import time
                time.sleep(0.1 * (attempt + 1))
            else:
                _log_error(f'db_write failed on {table}: {e}')
                return
        except Exception as e:
            _log_error(f'db_write failed on {table}: {e}')
            return


def db_query(sql: str, params: tuple = ()) -> list:
    """Run a SELECT and return list of Row objects."""
    try:
        with _connect() as conn:
            return conn.execute(sql, params).fetchall()
    except Exception as e:
        _log_error(f'db_query failed: {e}')
        return []


def db_execute(sql: str, params: tuple = ()) -> None:
    """Run a non-SELECT statement (INSERT/UPDATE/DELETE/PRAGMA)."""
    for attempt in range(3):
        try:
            with _connect() as conn:
                conn.execute(sql, params)
                conn.commit()
            return
        except sqlite3.OperationalError as e:
            if 'locked' in str(e) and attempt < 2:
                import time
                time.sleep(0.1 * (attempt + 1))
            else:
                _log_error(f'db_execute failed: {e}')
                return
        except Exception as e:
            _log_error(f'db_execute failed: {e}')
            return


def _log_error(msg: str) -> None:
    try:
        log_path = Path.home() / '.claude' / 'logs' / 'db-write-errors.log'
        log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.datetime.utcnow().isoformat() + 'Z'
        with open(log_path, 'a') as f:
            f.write(f'[{ts}] ERROR cast_db.py: {msg}\n')
    except Exception:
        pass
