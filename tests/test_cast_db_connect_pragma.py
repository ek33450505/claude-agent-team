#!/usr/bin/env python3
"""Tests for cast_db._connect PRAGMA hardening.

Verifies that every connection opened by cast_db has:
  - busy_timeout = 5000
  - journal_mode = wal
  - synchronous = NORMAL (1)

Uses a temp DB path so the real cast.db is never touched.
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_db  # noqa: E402


class TestConnectPragma(unittest.TestCase):
    """_connect sets required PRAGMAs on every new connection."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
        self._tmp.close()
        os.environ['CAST_DB_PATH'] = self._tmp.name

    def tearDown(self):
        os.unlink(self._tmp.name)
        os.environ.pop('CAST_DB_PATH', None)

    def _pragma(self, conn, name):
        return conn.execute(f'PRAGMA {name}').fetchone()[0]

    def test_busy_timeout_is_5000(self):
        conn = cast_db._connect()
        try:
            self.assertEqual(self._pragma(conn, 'busy_timeout'), 5000)
        finally:
            conn.close()

    def test_journal_mode_is_wal(self):
        conn = cast_db._connect()
        try:
            self.assertEqual(self._pragma(conn, 'journal_mode'), 'wal')
        finally:
            conn.close()

    def test_synchronous_is_normal(self):
        # NORMAL = 1
        conn = cast_db._connect()
        try:
            self.assertEqual(self._pragma(conn, 'synchronous'), 1)
        finally:
            conn.close()

    def test_pragma_hardening_does_not_break_db_write(self):
        """db_write still succeeds on a temp DB — PRAGMAs don't block writes."""
        import sqlite3
        # Create the sessions table so db_write can target it
        conn = cast_db._connect()
        conn.execute(
            "CREATE TABLE IF NOT EXISTS sessions "
            "(id TEXT PRIMARY KEY, started_at TEXT NOT NULL, status TEXT)"
        )
        conn.commit()
        conn.close()

        # db_write uses sessions which is in ALLOWED_TABLES
        result = cast_db.db_write('sessions', {
            'id': 'test-pragma-001',
            'started_at': '2026-06-10T00:00:00Z',
            'status': 'running',
        })
        self.assertTrue(result)

        rows = cast_db.db_query("SELECT id FROM sessions WHERE id='test-pragma-001'")
        self.assertEqual(len(rows), 1)


if __name__ == '__main__':
    unittest.main()
