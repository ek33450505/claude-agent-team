#!/usr/bin/env python3
"""CAST_DB_URL was retired in v10.4.0: every script that resolves the DB path itself
must REFUSE it (not ignore it and fall through to the live default DB), while an
explicit override (--db) still wins. cast_db.py's own refusal is covered in
test_cast_db_sql_injection.py.

Each script is loaded by file path (hyphenated names cannot be imported). All ten are
import-safe: their work happens under main()/`if __name__ == '__main__'`."""

import importlib.util
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS = Path(__file__).parent.parent / 'scripts'

# (script, resolver name, takes an explicit override as its first positional arg)
_RESOLVERS = [
    ('cast-memory-consolidate.py', 'get_db_path', False),
    ('cast-memory-embed.py', 'get_db_path', False),
    ('cast-memory-dream-review.py', 'get_db_path', False),
    ('cast-memory-dream-promote.py', 'get_db_path', False),
    ('cast-memory-dream.py', 'get_db_path', False),
    ('cast-memory-validate.py', 'get_db_path', False),
    ('cast-migrate.py', '_get_db_path', False),
    ('cast-ledger.py', '_get_db_path', True),
    ('cast-record-review.py', 'get_db_path', True),
    ('cast-provenance-chain.py', '_resolve_db_path', 'ledger'),
]


def _load(name):
    spec = importlib.util.spec_from_file_location(
        'urlretired_' + name.replace('-', '_').removesuffix('.py'), str(_SCRIPTS / name))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestUrlRetiredInResolvers(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp(prefix='cast-urlret-')
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        self.good = str(Path(d) / 'ok.db')

    def test_each_resolver_refuses_cast_db_url_with_valid_cast_db_path(self):
        for script, fn_name, _ in _RESOLVERS:
            with self.subTest(script=script):
                mod = _load(script)
                fn = getattr(mod, fn_name)
                args = (None,) if fn_name == '_resolve_db_path' else ()
                with mock.patch.dict(os.environ, {
                        'CAST_DB_URL': f'sqlite:///{self.good}', 'CAST_DB_PATH': self.good}):
                    with self.assertRaises(ValueError) as cm:
                        fn(*args)
                self.assertIn('retired', str(cm.exception))

    def test_each_resolver_uses_cast_db_path_when_url_unset(self):
        for script, fn_name, _ in _RESOLVERS:
            with self.subTest(script=script):
                fn = getattr(_load(script), fn_name)
                args = (None,) if fn_name == '_resolve_db_path' else ()
                with mock.patch.dict(os.environ, {'CAST_DB_PATH': self.good}):
                    os.environ.pop('CAST_DB_URL', None)
                    self.assertEqual(str(fn(*args)), self.good)

    def test_explicit_override_still_wins_where_supported(self):
        for script, fn_name, takes in _RESOLVERS:
            if not takes:
                continue
            with self.subTest(script=script):
                fn = getattr(_load(script), fn_name)
                args = (None, '/x/cli.db') if fn_name == '_resolve_db_path' else ('/x/cli.db',)
                with mock.patch.dict(os.environ, {'CAST_DB_URL': 'sqlite:////x/u.db'}):
                    self.assertEqual(fn(*args), '/x/cli.db')


if __name__ == '__main__':
    unittest.main()
