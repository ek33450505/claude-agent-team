#!/usr/bin/env python3
"""Tests for SQL-injection defenses in cast_db.py.

Covers:
  (a) valid identifier passes _validate_identifier
  (b) SQL-injection-shaped identifier raises ValueError
  (c) unknown table raises ValueError in db_write
  (d) invalid CAST_DB_URL raises ValueError in _get_db_path
"""
import os
import sys
import unittest
from pathlib import Path

# Resolve cast_db from the scripts/ sibling directory.
_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_db  # noqa: E402  (imported after path manipulation)


class TestValidateIdentifier(unittest.TestCase):
    """(a) valid identifiers pass; (b) injection-shaped names raise."""

    def test_valid_simple(self):
        self.assertEqual(cast_db._validate_identifier('sessions'), 'sessions')

    def test_valid_underscore_prefix(self):
        self.assertEqual(cast_db._validate_identifier('_tmp'), '_tmp')

    def test_valid_mixed(self):
        self.assertEqual(cast_db._validate_identifier('agent_runs'), 'agent_runs')

    def test_valid_uppercase(self):
        self.assertEqual(cast_db._validate_identifier('MyTable'), 'MyTable')

    # (b) injection-shaped identifiers

    def test_injection_semicolon(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('sessions; DROP TABLE sessions--')

    def test_injection_space(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('sessions WHERE 1=1')

    def test_injection_dash(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('table-name')

    def test_injection_paren(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('foo()')

    def test_injection_dot(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('schema.table')

    def test_empty_string(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('')

    def test_starts_with_digit(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('1bad')

    def test_star(self):
        with self.assertRaises(ValueError):
            cast_db._validate_identifier('*')


class TestAllowedTables(unittest.TestCase):
    """(c) db_write rejects tables not in ALLOWED_TABLES."""

    def test_unknown_table_raises(self):
        with self.assertRaises(ValueError, msg='unknown_table must be rejected'):
            cast_db.db_write('unknown_table', {'col': 'val'})

    def test_injection_table_raises(self):
        with self.assertRaises(ValueError):
            cast_db.db_write('sessions; DROP TABLE sessions--', {'col': 'val'})

    def test_allowed_table_name_is_in_set(self):
        # Smoke-check the ALLOWED_TABLES set itself.
        self.assertIn('sessions', cast_db.ALLOWED_TABLES)
        self.assertIn('agent_runs', cast_db.ALLOWED_TABLES)
        self.assertIn('routing_events', cast_db.ALLOWED_TABLES)

    def test_all_allowed_identifiers_are_valid(self):
        """Every entry in ALLOWED_TABLES must itself pass the identifier check."""
        for name in cast_db.ALLOWED_TABLES:
            try:
                cast_db._validate_identifier(name)
            except ValueError as e:
                self.fail(f'ALLOWED_TABLES entry {name!r} failed validation: {e}')


class TestDbPathValidation(unittest.TestCase):
    """(d) invalid CAST_DB_URL raises ValueError."""

    def _get_path_with_env(self, url=None, db_path=None):
        old_url = os.environ.pop('CAST_DB_URL', None)
        old_path = os.environ.pop('CAST_DB_PATH', None)
        try:
            if url is not None:
                os.environ['CAST_DB_URL'] = url
            if db_path is not None:
                os.environ['CAST_DB_PATH'] = db_path
            return cast_db._get_db_path()
        finally:
            if old_url is not None:
                os.environ['CAST_DB_URL'] = old_url
            elif 'CAST_DB_URL' in os.environ:
                del os.environ['CAST_DB_URL']
            if old_path is not None:
                os.environ['CAST_DB_PATH'] = old_path
            elif 'CAST_DB_PATH' in os.environ:
                del os.environ['CAST_DB_PATH']

    def test_default_path_is_valid(self):
        """No env vars set → default path accepted without raising."""
        result = self._get_path_with_env()
        self.assertIn('.claude', result)

    def test_tmp_cast_prefix_accepted(self):
        """Paths under /tmp/cast- are accepted (test fixtures)."""
        result = self._get_path_with_env(db_path='/tmp/cast-test/cast.db')
        self.assertEqual(result, '/tmp/cast-test/cast.db')

    def test_home_claude_subdir_accepted(self):
        home_claude = str(Path.home() / '.claude' / 'cast.db')
        result = self._get_path_with_env(db_path=home_claude)
        self.assertEqual(result, home_claude)

    def test_etc_passwd_traversal_raises(self):
        with self.assertRaises(ValueError):
            self._get_path_with_env(url='sqlite:////etc/passwd')

    def test_arbitrary_path_raises(self):
        with self.assertRaises(ValueError):
            self._get_path_with_env(db_path='/var/db/evil.db')

    def test_traversal_via_dotdot_raises(self):
        home_claude = str(Path.home() / '.claude' / '..' / 'evil.db')
        with self.assertRaises(ValueError):
            self._get_path_with_env(db_path=home_claude)


if __name__ == '__main__':
    unittest.main()
