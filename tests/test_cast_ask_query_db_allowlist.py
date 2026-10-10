"""S4-d D3: cast-ask-query.py must apply cast_db's DB allowlist to --db and the env path,
open the DB read-only, and never create a database (or its parent directory).

Also pins that factoring `validate_db_path` out of `cast_db._get_db_path` left the env-var
behaviour (accept/refuse + messages) unchanged.

Every run uses a CAST_DB_PATH-free, HOME-isolated subprocess and temp paths only.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent.parent / 'scripts'
_QUERY = _SCRIPTS / 'cast-ask-query.py'
sys.path.insert(0, str(_SCRIPTS))
import cast_db  # noqa: E402


def _seed(path: str) -> None:
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE VIRTUAL TABLE record_fts USING fts5("
        "kind, ref_id UNINDEXED, ts UNINDEXED, title, body, "
        "agent UNINDEXED, project UNINDEXED, mtype UNINDEXED)"
    )
    conn.execute(
        "INSERT INTO record_fts VALUES ('memory','1','2026-01-01','alpha title',"
        "'zebracorn body text','','','')"
    )
    conn.commit()
    conn.close()


class _Base(unittest.TestCase):
    def setUp(self):
        # Under /var/folders (macOS) or /tmp: inside the constant temp allowlist.
        self._td = tempfile.TemporaryDirectory(prefix='cast-askq-')
        self.addCleanup(self._td.cleanup)
        self.tmp = self._td.name
        self.home = os.path.join(self.tmp, 'home')
        os.makedirs(self.home)

    def run_query(self, *args, env_extra=None):
        env = {k: v for k, v in os.environ.items()
               if k not in ('CAST_DB_PATH', 'CAST_DB_URL')}
        env['HOME'] = self.home
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        if env_extra:
            env.update(env_extra)
        return subprocess.run([sys.executable, '-I', str(_QUERY), *args],
                              capture_output=True, text=True, env=env, timeout=60)


class TestAskQueryDbAllowlist(_Base):
    def test_allowlisted_temp_db_works(self):
        db = os.path.join(self.tmp, 'ok.db')
        _seed(db)
        r = self.run_query('zebracorn', '--db', db)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = json.loads(r.stdout)
        self.assertEqual([x['ref_id'] for x in rows], ['1'])

    def test_env_path_allowlisted_works(self):
        db = os.path.join(self.tmp, 'env.db')
        _seed(db)
        r = self.run_query('zebracorn', env_extra={'CAST_DB_PATH': db})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(json.loads(r.stdout)), 1)

    def test_path_outside_allowlist_is_refused_and_not_created(self):
        # /var/db/ is outside ~/.claude and every temp root on macOS and Linux.
        target = '/var/db/cast-askq-evil-%d.db' % os.getpid()
        self.addCleanup(lambda: os.path.exists(target) and os.remove(target))
        r = self.run_query('zebracorn', '--db', target)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertNotIn('Traceback', r.stderr)
        self.assertIn('--db', r.stderr)
        self.assertIn('unexpected path', r.stderr)
        self.assertFalse(os.path.exists(target))

    def test_env_path_outside_allowlist_is_refused(self):
        r = self.run_query('zebracorn', env_extra={'CAST_DB_PATH': '/var/db/cast-askq-evil.db'})
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertNotIn('Traceback', r.stderr)
        self.assertIn('CAST_DB_URL/CAST_DB_PATH', r.stderr)
        self.assertFalse(os.path.exists('/var/db/cast-askq-evil.db'))

    def test_claude_subdir_and_non_db_refused(self):
        claude = os.path.join(self.home, '.claude')
        os.makedirs(claude)
        for rel in ('scripts/x.db', 'settings.json', 'evil.sh'):
            with self.subTest(rel=rel):
                r = self.run_query('zebracorn', '--db', os.path.join(claude, rel))
                self.assertEqual(r.returncode, 1, r.stderr)
                self.assertNotIn('Traceback', r.stderr)
                self.assertIn('--db', r.stderr)
        self.assertEqual(os.listdir(claude), [])

    def test_missing_db_is_not_created_and_parent_not_made(self):
        parent = os.path.join(self.tmp, 'no', 'such', 'dir')
        db = os.path.join(parent, 'absent.db')
        r = self.run_query('zebracorn', '--db', db)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertTrue(out.get('degraded'))
        self.assertIn('not found', out.get('note', ''))
        self.assertFalse(os.path.exists(db))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, 'no')))

    def test_missing_default_db_is_not_created(self):
        # HOME has no .claude at all; the default cast.db must not be conjured up.
        r = self.run_query('zebracorn')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(json.loads(r.stdout).get('degraded'))
        self.assertFalse(os.path.exists(os.path.join(self.home, '.claude')))

    def test_question_mark_and_hash_in_path(self):
        d = os.path.join(self.tmp, 'we?ird#dir')
        os.makedirs(d)
        db = os.path.join(d, 'q?x#y.db')
        _seed(db)
        r = self.run_query('zebracorn', '--db', db)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(json.loads(r.stdout)), 1)

    def test_connection_is_read_only(self):
        db = os.path.join(self.tmp, 'ro.db')
        _seed(db)
        import importlib.util
        spec = importlib.util.spec_from_file_location('cast_ask_query_under_test', _QUERY)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        conn = mod._connect(cast_db.validate_db_path(db))
        try:
            with self.assertRaises(sqlite3.OperationalError):
                conn.execute("INSERT INTO record_fts (kind) VALUES ('x')")
        finally:
            conn.close()


class TestValidateDbPathParity(unittest.TestCase):
    """_get_db_path (env vars) keeps identical behaviour after the factor-out."""

    def _env(self, url=None, db_path=None):
        saved = {k: os.environ.pop(k, None) for k in ('CAST_DB_URL', 'CAST_DB_PATH')}
        try:
            if url is not None:
                os.environ['CAST_DB_URL'] = url
            if db_path is not None:
                os.environ['CAST_DB_PATH'] = db_path
            return cast_db._get_db_path()
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None)
                if v is not None:
                    os.environ[k] = v

    def test_env_accepts_tmp_and_returns_resolved(self):
        self.assertEqual(self._env(db_path='/tmp/cast-x/cast.db'),
                         str(Path('/tmp/cast-x/cast.db').resolve()))

    def test_env_url_form_refused_with_legacy_message(self):
        with self.assertRaises(ValueError) as cm:
            self._env(url='sqlite:////etc/passwd')
        self.assertIn('CAST_DB_URL/CAST_DB_PATH resolves to an unexpected path', str(cm.exception))

    def test_env_claude_subdir_refused_with_legacy_message(self):
        p = str(Path.home() / '.claude' / 'scripts' / 'x.db')
        with self.assertRaises(ValueError) as cm:
            self._env(db_path=p)
        self.assertIn('CAST_DB_URL/CAST_DB_PATH is inside a ~/.claude subdirectory', str(cm.exception))

    def test_validate_matches_get_db_path_and_label_is_used(self):
        self.assertEqual(cast_db.validate_db_path('/tmp/cast-x/cast.db'),
                         self._env(db_path='/tmp/cast-x/cast.db'))
        with self.assertRaises(ValueError) as cm:
            cast_db.validate_db_path('/var/db/evil.db', label='--db')
        self.assertTrue(str(cm.exception).startswith('--db resolves to an unexpected path'))


if __name__ == '__main__':
    unittest.main()
