#!/usr/bin/env python3
"""Tests for scripts/cast_ack.py — escape-hatch acknowledgment recorder.

CAST v10 I-3a part 1: this covers the record_ack() primitive and its CLI
entrypoint in isolation. It does NOT test any escape hatch actually calling
cast_ack.py yet — wiring the 19 callers is a separate unit.

HOME is redirected to an isolated temp dir for every test (the Python-test
analogue of the BATS setup_temp_home/teardown_temp_home HARD RULE), and
CAST_DB_PATH points at a temp sqlite file seeded with the ack_events schema
from scripts/migrations/034_ack_events.sql — never the real ~/.claude/cast.db.
"""
import io
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

_MIGRATION_SQL = str(
    Path(__file__).parent.parent / 'scripts' / 'migrations' / '034_ack_events.sql'
)

import cast_ack  # noqa: E402


class _IsolatedDbTestCase(unittest.TestCase):
    """Redirects HOME to an isolated temp dir (so any error logging never
    touches the real ~/.claude), and points CAST_DB_PATH at a fresh temp
    sqlite file seeded with the ack_events schema."""

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._orig_db_path = os.environ.get('CAST_DB_PATH')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-ack-test-')
        os.environ['HOME'] = self._tmpdir

        self._db_path = os.path.join(self._tmpdir, 'test-cast.db')
        conn = sqlite3.connect(self._db_path)
        with open(_MIGRATION_SQL) as f:
            conn.executescript(f.read())
        conn.close()
        os.environ['CAST_DB_PATH'] = self._db_path

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        if self._orig_db_path is None:
            os.environ.pop('CAST_DB_PATH', None)
        else:
            os.environ['CAST_DB_PATH'] = self._orig_db_path
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _rows(self):
        conn = sqlite3.connect(self._db_path)
        conn.row_factory = sqlite3.Row
        rows = conn.execute('SELECT * FROM ack_events').fetchall()
        conn.close()
        return rows


class TestRecordAck(_IsolatedDbTestCase):

    def test_unset_var_returns_false_writes_no_row(self):
        os.environ.pop('CAST_ACK_TEST_VAR', None)
        result = cast_ack.record_ack('CAST_ACK_TEST_VAR')
        self.assertFalse(result)
        self.assertEqual(len(self._rows()), 0)

    def test_empty_string_var_returns_false_writes_no_row(self):
        os.environ['CAST_ACK_TEST_VAR'] = ''
        result = cast_ack.record_ack('CAST_ACK_TEST_VAR')
        self.assertFalse(result)
        self.assertEqual(len(self._rows()), 0)
        os.environ.pop('CAST_ACK_TEST_VAR', None)

    def test_bare_1_writes_row_with_has_reason_zero_and_warns(self):
        buf = io.StringIO()
        with redirect_stderr(buf):
            result = cast_ack.record_ack('CAST_ACK_TEST_VAR', value='1')
        self.assertTrue(result)
        rows = self._rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['has_reason'], 0)
        self.assertIn('CAST_ACK_TEST_VAR', buf.getvalue())
        self.assertIn('recorded without a reason', buf.getvalue())

    def test_reason_string_writes_row_with_has_reason_one_no_warn(self):
        buf = io.StringIO()
        reason = 'CI outage, hooks agent unreachable'
        with redirect_stderr(buf):
            result = cast_ack.record_ack('CAST_ACK_TEST_VAR', value=reason)
        self.assertTrue(result)
        rows = self._rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['has_reason'], 1)
        self.assertEqual(rows[0]['value'], reason)
        self.assertEqual(buf.getvalue(), '')

    def test_control_chars_are_sanitized(self):
        dirty = 'reason\x00with\x1fcontrol\x7fchars'
        cast_ack.record_ack('CAST_ACK_TEST_VAR', value=dirty)
        rows = self._rows()
        self.assertEqual(len(rows), 1)
        stored = rows[0]['value']
        for ch in ('\x00', '\x1f', '\x7f'):
            self.assertNotIn(ch, stored)
        self.assertIn('reason', stored)
        self.assertIn('with', stored)

    def test_value_over_500_chars_is_truncated(self):
        long_value = 'x' * 600
        cast_ack.record_ack('CAST_ACK_TEST_VAR', value=long_value)
        rows = self._rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]['value']), 500)

    def test_variable_recorded_exactly_as_passed(self):
        cast_ack.record_ack('CAST_SOME_WEIRD_HATCH_NAME', value='because reasons')
        rows = self._rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['variable'], 'CAST_SOME_WEIRD_HATCH_NAME')


class TestCliNeverBreaksPipeline(_IsolatedDbTestCase):

    def test_cli_exits_zero_even_when_db_path_unwritable(self):
        # Point CAST_DB_PATH at a path under a directory that does not
        # exist and cannot be created (parent is a file, not a dir), so
        # any DB write attempt fails — the CLI must still exit 0.
        blocker_file = os.path.join(self._tmpdir, 'not-a-dir')
        with open(blocker_file, 'w') as f:
            f.write('x')
        unwritable_db = os.path.join(blocker_file, 'sub', 'cast.db')

        env = os.environ.copy()
        env['CAST_ACK_TEST_VAR'] = '1'
        env['CAST_DB_PATH'] = unwritable_db
        result = subprocess.run(
            [sys.executable, str(Path(_SCRIPTS_DIR) / 'cast_ack.py'), 'CAST_ACK_TEST_VAR'],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0)

    def test_cli_script_flag_without_value_still_records(self):
        """`--script` with no following value must be handled by the bounds
        check, not by the outer exception handler: the CLI exits 0 AND the row
        is still written (script=None). Asserting only the exit code would pass
        even if the guard were deleted, since main() swallows IndexError."""
        reason = 'reason string with no --script value following the flag'
        env = os.environ.copy()
        env['CAST_ACK_SCRIPT_FLAG_VAR'] = reason
        env['CAST_DB_PATH'] = self._db_path
        result = subprocess.run(
            [
                sys.executable,
                str(Path(_SCRIPTS_DIR) / 'cast_ack.py'),
                'CAST_ACK_SCRIPT_FLAG_VAR',
                '--script',  # flag last, deliberately no value after it
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0)

        rows = self._rows()
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0]['script'])
        self.assertEqual(rows[0]['value'], reason)


if __name__ == '__main__':
    unittest.main()
