#!/usr/bin/env python3
"""Tests for the content-bound review gate on scripts/cast-git-guard.py's
`CAST_COMMIT_AGENT=1 git commit` allow path (U4): `_review_gate_check`,
`_review_gate_shape`, `_review_gate_module`.

WARN mode logs a review_gate_decisions row (source='guard') and never blocks; ENFORCE mode
(a later one-line PATCH) blocks unreviewed or unverifiable commits. Every test runs against a
temp HOME, a temp cast.db built by cast-db-init.sh, and temp git repos.
"""
import importlib.util
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_GATE_PATH = str(_SCRIPTS_DIR / 'cast-review-gate.py')

_spec = importlib.util.spec_from_file_location('cast_git_guard', str(_SCRIPTS_DIR / 'cast-git-guard.py'))
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

_snap_spec = importlib.util.spec_from_file_location(
    'cast_review_snapshot', str(_SCRIPTS_DIR / 'cast_review_snapshot.py'))
crs = importlib.util.module_from_spec(_snap_spec)
_snap_spec.loader.exec_module(crs)

T_OLD = '2026-10-15T10:00:00Z'
T_MID = '2026-10-15T11:00:00Z'

COMMIT = 'CAST_COMMIT_AGENT=1 git commit -F msg.txt'


class GuardGateCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tpl_dir = tempfile.mkdtemp(prefix='guardgate-tpl-')
        cls._tpl_db = os.path.join(cls._tpl_dir, 'cast.db')
        home = os.path.join(cls._tpl_dir, 'home')
        os.makedirs(home)
        env = dict(os.environ, HOME=home, CAST_DB_PATH=cls._tpl_db)
        subprocess.run(['bash', str(_SCRIPTS_DIR / 'cast-db-init.sh')], env=env,
                       capture_output=True, check=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tpl_dir, ignore_errors=True)

    def make_home(self, name):
        home = os.path.join(self.tmp, name)
        os.makedirs(os.path.join(home, '.claude'))
        db = os.path.join(home, '.claude', 'cast.db')
        shutil.copy(self._tpl_db, db)
        return home, db

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix='guardgate-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home, self.db = self.make_home('home')
        self.repo = os.path.join(self.tmp, 'repo')
        os.makedirs(self.repo)
        self.git('init', '-q')
        self.git('config', 'user.name', 't')
        self.git('config', 'user.email', 't@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.write('base.txt', 'base\n')
        self.git('add', 'base.txt')
        self.git('commit', '-q', '-m', 'base')
        self.write('msg.txt', 'message\n')   # untracked: never staged
        self.write('a.txt', 'one\n')
        self.git('add', 'a.txt')
        self.blob = self.git('hash-object', '--no-filters', '--', 'a.txt').strip()

        patches = [
            mock.patch.dict(os.environ, {'HOME': self.home, 'CAST_DB_PATH': self.db}),
            mock.patch.object(guard, '_REVIEW_GATE_TEST_HOME', self.home),
            mock.patch.object(guard, '_REVIEW_GATE_MODE', 'warn'),
            mock.patch.object(guard, '_HOOK_CTX', {'session_id': 'sess-1'}),
            mock.patch.object(guard, '_HOOK_CWD', self.repo),
            mock.patch.object(guard, '_GUARD_ENTRY', None),   # a stale stamp would age direct calls
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.cwd0 = os.getcwd()
        os.chdir(self.repo)
        self.addCleanup(os.chdir, self.cwd0)

    # ---- fixtures ----
    def cd(self, path):
        """Move both the guard process cwd and the hook payload cwd (the shell cwd)."""
        os.chdir(path)
        p = mock.patch.object(guard, '_HOOK_CWD', path)
        p.start()
        self.addCleanup(p.stop)

    def git(self, *args):
        env = dict(os.environ, HOME=self.home, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        r = subprocess.run(['git'] + list(args), cwd=self.repo, env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def write(self, rel, content):
        with open(os.path.join(self.repo, rel), 'w') as fh:
            fh.write(content)

    def seed(self, decision='APPROVE', db=None, path='a.txt', blob=None):
        ok = crs.record(
            db or self.db, session_id='s', agent_id='a', reviewer='code-reviewer',
            repo_root=self.repo, decision=decision, started_at=T_OLD, ended_at=T_MID,
            files={path: blob or self.blob}, modes={path: '100644'})
        self.assertTrue(ok)

    def rows(self):
        conn = sqlite3.connect(self.db)
        conn.row_factory = sqlite3.Row
        try:
            return conn.execute('SELECT * FROM review_gate_decisions').fetchall()
        finally:
            conn.close()

    def enforce(self):
        p = mock.patch.object(guard, '_REVIEW_GATE_MODE', 'enforce')
        p.start()
        self.addCleanup(p.stop)

    def ev(self, command):
        return guard._git_evaluate(command)

    def assertGateBlock(self, command):
        code, msg = self.ev(command)
        self.assertEqual(code, 2, command)
        self.assertIn('review gate', msg, command)


class TestWarnMode(GuardGateCase):
    def test_approved_allows_and_logs_clean_row(self):
        self.seed()
        self.assertEqual(self.ev(COMMIT)[0], 0)
        (row,) = self.rows()
        self.assertEqual((row['would_block'], row['source'], row['mode']), (0, 'guard', 'warn'))
        self.assertEqual(row['session_id'], 'sess-1')

    def test_unreviewed_allows_and_logs_would_block(self):
        self.assertEqual(self.ev(COMMIT)[0], 0)
        (row,) = self.rows()
        self.assertEqual((row['would_block'], row['source'], row['mode']), (1, 'guard', 'warn'))

    def test_unverifiable_allows_and_logs_would_block(self):
        self.seed()
        self.assertEqual(self.ev('git add x && ' + COMMIT)[0], 0)
        (row,) = self.rows()
        self.assertEqual(row['would_block'], 1)
        self.assertIn('unverifiable-command', row['reasons'])

    def test_gate_module_missing_allows_without_exception(self):
        with mock.patch.object(guard, '_REVIEW_GATE_MODULE_PATH', os.path.join(self.tmp, 'nope.py')):
            self.assertEqual(self.ev(COMMIT)[0], 0)

    def test_evaluate_raising_allows(self):
        mod = guard._review_gate_module()
        with mock.patch.object(mod, 'evaluate', side_effect=RuntimeError('boom')):
            self.assertEqual(self.ev(COMMIT)[0], 0)


class TestNonCommitUnaffected(GuardGateCase):
    def test_non_commit_never_loads_gate_module(self):
        sentinel = mock.Mock(side_effect=AssertionError('gate module loaded'))
        with mock.patch.object(guard, '_review_gate_module', sentinel):
            for cmd in ('git status', 'git log -1', 'ls -la', 'git add a.txt', 'git commit -m x'):
                self.ev(cmd)   # the un-hatched commit blocks on the old path, still no gate
        sentinel.assert_not_called()


class TestEnforceMode(GuardGateCase):
    def setUp(self):
        super().setUp()
        self.enforce()

    def test_unreviewed_blocks_naming_path_and_remedies(self):
        code, msg = self.ev(COMMIT)
        self.assertEqual(code, 2)
        self.assertIn('a.txt', msg)
        self.assertIn('code-reviewer', msg)
        self.assertIn('CAST_UNREVIEWED_OK', msg)
        (row,) = self.rows()
        self.assertEqual((row['mode'], row['would_block']), ('enforce', 1))

    def test_approved_allows(self):
        self.seed()
        self.assertEqual(self.ev(COMMIT), (0, None))

    def test_unverifiable_shapes_block_even_when_approved(self):
        self.seed()
        shapes = [
            'git add x && ' + COMMIT,
            'cd sub && ' + COMMIT,
            'echo hi; ' + COMMIT,
            'CAST_COMMIT_AGENT=1 git commit -a -F msg.txt',
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt a.txt',
            'CAST_COMMIT_AGENT=1 git commit --no-verify -F msg.txt',
            'CAST_COMMIT_AGENT=1 git commit -am x',
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt -- a.txt',
            'CAST_COMMIT_AGENT=1 git commit -m "$(echo hi)"',
            'CAST_COMMIT_AGENT=1 git commit -m "`echo hi`"',
            'CAST_COMMIT_AGENT=1 GIT_DIR=/elsewhere git commit -F msg.txt',
            'CAST_COMMIT_AGENT=1 GIT_INDEX_FILE=/x git commit -F msg.txt',
            'CAST_COMMIT_AGENT=1 git -c core.hooksPath=/x commit -F msg.txt',
            'CAST_COMMIT_AGENT=1 git -C "$HOME" commit -F msg.txt',
            'CAST_COMMIT_AGENT=1 git -C ~/x commit -F msg.txt',
            'CAST_COMMIT_AGENT=1 git commit -m "unbalanced',
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt > .git/index',
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt 2> ./.GIT/index',
            f'CAST_COMMIT_AGENT=1 git commit -F msg.txt >> {self.repo}/.git/index 2>&1',
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt > /dev/stdin',
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt > "$LOG" 2>&1',
        ]
        for cmd in shapes:
            with self.subTest(cmd=cmd):
                self.assertGateBlock(cmd)

    def test_dash_C_evaluates_target_repo_from_another_cwd(self):
        self.seed()
        other = os.path.join(self.tmp, 'other')
        os.makedirs(other)
        self.cd(other)
        self.assertEqual(self.ev(f'CAST_COMMIT_AGENT=1 git -C {self.repo} commit -F msg.txt'), (0, None))
        # relative -C resolves against the cwd
        self.assertEqual(self.ev('CAST_COMMIT_AGENT=1 git -C ../repo commit -F msg.txt'), (0, None))

    def test_dash_C_unreviewed_repo_blocks_from_another_cwd(self):
        other = os.path.join(self.tmp, 'other')
        os.makedirs(other)
        self.cd(other)   # cwd is not a repo; the staged file lives in the -C target
        self.assertGateBlock(f'CAST_COMMIT_AGENT=1 git -C {self.repo} commit -F msg.txt')

    def test_gate_module_missing_blocks(self):
        with mock.patch.object(guard, '_REVIEW_GATE_MODULE_PATH', os.path.join(self.tmp, 'nope.py')):
            self.assertGateBlock(COMMIT)

    def test_gate_module_symlink_blocks(self):
        self.seed()
        link = os.path.join(self.tmp, 'cast-review-gate.py')
        os.symlink(_GATE_PATH, link)
        with mock.patch.object(guard, '_REVIEW_GATE_MODULE_PATH', link):
            self.assertGateBlock(COMMIT)

    def test_evaluate_raising_blocks(self):
        self.seed()
        mod = guard._review_gate_module()
        with mock.patch.object(mod, 'evaluate', side_effect=RuntimeError('boom')):
            self.assertGateBlock(COMMIT)

    def test_evaluate_error_blocks(self):
        self.seed()
        mod = guard._review_gate_module()
        bad = {'results': [], 'counts': {}, 'would_block': 1, 'db_ok': False,
               'error': 'budget', 'root': self.repo, 'staged': True}
        with mock.patch.object(mod, 'evaluate', return_value=bad):
            self.assertGateBlock(COMMIT)

    def test_not_a_repo_allows(self):
        self.cd(self.tmp)
        self.assertEqual(self.ev(COMMIT)[0], 0)

    def test_env_home_and_db_are_ignored(self):
        """L1: HOME / CAST_DB_PATH are agent-steerable; a forged APPROVE there must not count."""
        forged_home, forged_db = self.make_home('forged')
        self.seed(db=forged_db)
        real_home = types.SimpleNamespace(pw_dir=self.home)
        with mock.patch.object(guard, '_REVIEW_GATE_TEST_HOME', None), \
                mock.patch.object(guard.pwd, 'getpwuid', return_value=real_home), \
                mock.patch.dict(os.environ, {'HOME': forged_home, 'CAST_DB_PATH': forged_db}):
            self.assertGateBlock(COMMIT)

    def test_unreviewed_hatch_allows(self):
        self.assertEqual(self.ev('CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs git commit -F msg.txt'), (0, None))

    def test_unreviewed_hatch_never_overrides_recorded_block(self):
        self.seed('BLOCKED')
        self.assertGateBlock('CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs git commit -F msg.txt')

    def test_hatch_from_environment_is_not_read(self):
        with mock.patch.dict(os.environ, {'CAST_UNREVIEWED_OK': 'docs'}):
            self.assertGateBlock(COMMIT)

    def test_evaluate_budget_leaves_headroom(self):
        mod = guard._review_gate_module()
        seen = {}

        def slow(root, **kw):
            seen.update(kw)
            time.sleep(0.2)
            return {'results': [], 'counts': {}, 'would_block': 0, 'db_ok': True,
                    'error': None, 'root': root, 'staged': False}

        t0 = time.monotonic()
        with mock.patch.object(mod, 'evaluate', side_effect=slow):
            self.assertEqual(self.ev(COMMIT)[0], 0)
        self.assertLessEqual(seen['budget_s'], guard._REVIEW_GATE_BUDGET_S - 0.5)
        self.assertLess(time.monotonic() - t0, guard._REVIEW_GATE_BUDGET_S)


class TestHatchRecording(GuardGateCase):
    def test_hatch_recorded_once_via_guard_and_never_by_gate(self):
        self.enforce()
        mod = guard._review_gate_module()
        with mock.patch.object(mod, 'record_hatch', side_effect=AssertionError('gate recorded')), \
                mock.patch.object(guard, '_record_hatch') as rec:
            self.assertEqual(self.ev('CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs git commit -F msg.txt'), (0, None))
        hatch_calls = [c for c in rec.call_args_list if c.args[0] == 'CAST_UNREVIEWED_OK']
        self.assertEqual(len(hatch_calls), 1, rec.call_args_list)
        self.assertEqual(hatch_calls[0].args[2], 'commit')

    def test_no_hatch_record_when_nothing_hatched(self):
        self.seed()
        with mock.patch.object(guard, '_record_hatch') as rec:
            self.ev('CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs git commit -F msg.txt')
        self.assertFalse([c for c in rec.call_args_list if c.args[0] == 'CAST_UNREVIEWED_OK'])


class TestBudget(GuardGateCase):
    """The budget is measured from guard entry: with 3.8 s of the 4.0 s hook budget already
    spent, the gate must not start."""

    def _aged(self, mod):
        return (mock.patch.object(guard, '_GUARD_ENTRY', time.monotonic() - 3.8),
                mock.patch.object(mod, 'evaluate', side_effect=AssertionError('evaluate ran')))

    def test_spent_hook_budget_skips_evaluate_warn_allows_and_logs(self):
        mod = guard._review_gate_module()
        p1, p2 = self._aged(mod)
        with p1, p2:
            self.assertEqual(guard._review_gate_check(COMMIT, first_segment=True), (None, False))
        (row,) = self.rows()   # a row exists only if evaluate was skipped, not if it raised
        self.assertEqual(row['would_block'], 1)
        self.assertIn('budget', row['reasons'])

    def test_spent_hook_budget_enforce_blocks(self):
        self.enforce()
        self.seed()
        mod = guard._review_gate_module()
        p1, p2 = self._aged(mod)
        with p1, p2:
            msg, hatched = guard._review_gate_check(COMMIT, first_segment=True)
        self.assertIn('review gate', msg)
        self.assertIn('budget', self.rows()[0]['reasons'])

    def test_fresh_entry_runs_evaluate(self):
        mod = guard._review_gate_module()
        seen = {}

        def stub(root, **kw):
            seen.update(kw)
            return {'results': [], 'counts': {}, 'would_block': 0, 'db_ok': True,
                    'error': None, 'root': root, 'staged': False}

        with mock.patch.object(guard, '_GUARD_ENTRY', time.monotonic()), \
                mock.patch.object(mod, 'evaluate', side_effect=stub):
            guard._review_gate_check(COMMIT, first_segment=True)
        self.assertLessEqual(seen['budget_s'], 1.5)
        self.assertIs(seen['audit_hatch'], False)

    def test_spent_parse_budget_spawns_no_git_for_redirect_lookup(self):
        cmd = f'CAST_COMMIT_AGENT=1 git commit -F {self.repo}/msg.txt > {self.tmp}/out.log 2>&1'
        with mock.patch.object(guard, '_GUARD_ENTRY', time.monotonic() - 1.6), \
                mock.patch.object(guard, '_load_git_safe', return_value=mock.Mock(
                    run=mock.Mock(side_effect=AssertionError('git spawned')))):
            self.assertEqual(guard._review_gate_git_dirs([self.repo]), (None, 'budget'))
            self.assertEqual(guard._review_gate_shape(cmd, self.repo), (None, 'budget'))
            # warn allows (and logs the reason), enforce blocks
            self.assertEqual(guard._review_gate_check(cmd, first_segment=True), (None, False))
        self.assertIn('unverifiable-command:budget', self.rows()[0]['reasons'])
        self.enforce()
        self.seed()
        with mock.patch.object(guard, '_GUARD_ENTRY', time.monotonic() - 1.6), \
                mock.patch.object(guard, '_load_git_safe', return_value=mock.Mock(
                    run=mock.Mock(side_effect=AssertionError('git spawned')))):
            msg, _ = guard._review_gate_check(cmd, first_segment=True)
        self.assertIn('review gate', msg)

    def test_each_git_dir_spawn_is_capped_by_the_deadline(self):
        seen = []

        def fake_run(d, args, timeout=10.0):
            seen.append(timeout)
            return types.SimpleNamespace(returncode=0, stdout=d + '/.git\n')

        with mock.patch.object(guard, '_GUARD_ENTRY', time.monotonic() - 1.2), \
                mock.patch.object(guard, '_load_git_safe', return_value=mock.Mock(run=fake_run)):
            dirs, why = guard._review_gate_git_dirs([self.repo])
        self.assertIsNone(why)
        self.assertTrue(seen and all(t <= 0.31 for t in seen), seen)

    def test_git_evaluate_stamps_guard_entry(self):
        with mock.patch.object(guard, '_GUARD_ENTRY', None):
            self.ev('git status')
            self.assertIsNotNone(guard._GUARD_ENTRY)


class TestShellCwd(GuardGateCase):
    def setUp(self):
        super().setUp()
        self.enforce()
        self.seed()

    def test_missing_payload_cwd_is_unverifiable_and_logs_nothing(self):
        with mock.patch.object(guard, '_HOOK_CWD', ''):
            self.assertGateBlock(COMMIT)
        self.assertEqual(self.rows(), [])

    def test_missing_payload_cwd_allowed_in_warn(self):
        p = mock.patch.object(guard, '_REVIEW_GATE_MODE', 'warn')
        p.start()
        self.addCleanup(p.stop)
        with mock.patch.object(guard, '_HOOK_CWD', ''):
            self.assertEqual(self.ev(COMMIT)[0], 0)

    def test_relative_dash_C_resolves_against_payload_cwd(self):
        deep = os.path.join(self.tmp, 'deep', 'x')
        os.makedirs(deep)
        self.seed(path='a.txt')   # approved: evaluating the real repo allows
        with mock.patch.object(guard, '_HOOK_CWD', deep):
            # process cwd is the repo, where ../../repo does not exist; the payload cwd finds it
            self.assertEqual(self.ev('CAST_COMMIT_AGENT=1 git -C ../../repo commit -F msg.txt'), (0, None))

    def test_relative_dash_C_unreviewed_repo_found_via_payload_cwd(self):
        deep = os.path.join(self.tmp, 'deep', 'x')
        os.makedirs(deep)
        self.write('b.txt', 'two\n')
        self.git('add', 'b.txt')   # staged but unreviewed
        with mock.patch.object(guard, '_HOOK_CWD', deep):
            self.assertGateBlock('CAST_COMMIT_AGENT=1 git -C ../../repo commit -F msg.txt')

    def test_redirect_resolves_against_shell_cwd_not_dash_C_target(self):
        """cwd=<repo>/.git: `> config` truncates .git/config, though -C names the work tree."""
        gitdir = os.path.join(self.repo, '.git')
        with mock.patch.object(guard, '_HOOK_CWD', gitdir):
            self.assertGateBlock(f'CAST_COMMIT_AGENT=1 git -C {self.repo} commit -F {self.repo}/msg.txt > config')

    def test_redirect_into_separate_git_dir_rejected(self):
        sep = os.path.join(self.tmp, 'sepgit')
        work = os.path.join(self.tmp, 'sepwork')
        os.makedirs(work)
        env = dict(os.environ, HOME=self.home, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        subprocess.run(['git', 'init', '-q', f'--separate-git-dir={sep}', work], env=env, check=True)
        self.assertTrue(os.path.isfile(os.path.join(work, '.git')))   # a gitfile
        with mock.patch.object(guard, '_HOOK_CWD', work):
            self.assertGateBlock(f'CAST_COMMIT_AGENT=1 git commit -F {self.repo}/msg.txt > {sep}/index')
            self.assertGateBlock(f'CAST_COMMIT_AGENT=1 git commit -F {self.repo}/msg.txt > {sep}/config 2>&1')
            # a plain log in the work tree is fine (no staged content there -> allowed)
            self.assertEqual(self.ev(f'CAST_COMMIT_AGENT=1 git commit -F {self.repo}/msg.txt > {work}/out.log 2>&1')[0], 0)

    def test_set_hook_context_validates_cwd(self):
        guard.set_hook_context({'cwd': self.repo})
        self.assertEqual(guard._HOOK_CWD, self.repo)
        for bad in (None, '', 'relative/dir', os.path.join(self.tmp, 'missing'), 'a\0b', 5):
            guard.set_hook_context({'cwd': bad})
            self.assertEqual(guard._HOOK_CWD, '', repr(bad))
        guard.set_hook_context({'cwd': self.repo})
        guard.clear_hook_context()
        self.assertEqual(guard._HOOK_CWD, '')
        guard.set_hook_context('not a dict')
        self.assertEqual(guard._HOOK_CWD, '')

    def test_not_a_repo_allows_but_logs_a_row(self):
        self.cd(self.tmp)   # not a repo
        self.assertEqual(self.ev(COMMIT)[0], 0)
        (row,) = self.rows()
        self.assertEqual((row['would_block'], row['n_staged']), (0, 0))
        self.assertIn('not-a-repo', row['reasons'])


# Shell-expansion bypasses: shlex keeps an unquoted expansion as one token, bash expands and
# word-splits it. Every one of these must be unverifiable.
MUST_REJECT = [
    'CAST_COMMIT_AGENT=1 git commit -m a${Z:-x${IFS}-a}',
    'CAST_COMMIT_AGENT=1 git commit -m a$Z',
    'CAST_COMMIT_AGENT=1 git commit -m ${Z}',
    'CAST_COMMIT_AGENT=1 git commit -m "$Z"',
    'CAST_COMMIT_AGENT=1 git commit -m "a`b`"',
    'CAST_COMMIT_AGENT=1 git commit -m "a\\"b"',
    'CAST_COMMIT_AGENT=1 git commit -m a\\ -a',
    'CAST_COMMIT_AGENT=1 git -C rep? commit -F m',
    'CAST_COMMIT_AGENT=1 git -C rep* commit -F m',
    'CAST_COMMIT_AGENT=1 git -C {repo,x} commit -F m',
    'CAST_COMMIT_AGENT=1 git -C r[e]po commit -F m',
    'CAST_COMMIT_AGENT=1 git -C ~ commit -F m',
    'CAST_COMMIT_AGENT=1 git commit -m a*',
    'CAST_COMMIT_AGENT=1 git commit -m ?',
    'CAST_COMMIT_AGENT=1 git commit -m {a,b}',
    'CAST_COMMIT_AGENT=1 git commit -m ~root',
    'CAST_COMMIT_AGENT=1 git commit -m a#b',
    'CAST_COMMIT_AGENT=1 git commit -m !x',
    'CAST_COMMIT_AGENT=1 git commit -m ^zz',            # zsh extendedglob negation
    'CAST_COMMIT_AGENT=1 git commit -m =ls',            # zsh =cmd expansion
    'CAST_COMMIT_AGENT=1 git commit -F =ls',
    '"CAST_COMMIT_AGENT=1" git commit -F msg.txt',
    "CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK='x' git commit -F msg.txt",
    'CAST_COMMIT_AGENT=1 CAST_HATCH_REASON="x y" git commit -F msg.txt',
    "CAST_COMMIT_AGENT=1 git commit -m 'unterminated",
    'CAST_COMMIT_AGENT=1 git commit -m "unterminated',
    "CAST_COMMIT_AGENT=1 git commit -m $'a'",
    'CAST_COMMIT_AGENT=1 git commit -m a$(echo)',
    "CAST_COMMIT_AGENT=1 git commit -F msg.txt '>' x",
    'CAST_COMMIT_AGENT=1 git commit -F > x',
    'CAST_COMMIT_AGENT=1 git commit -m a&b',
    'CAST_COMMIT_AGENT=1 git commit -m (a)',
    'CAST_COMMIT_AGENT=1 git commit -F msg.txt <in',
    'CAST_COMMIT_AGENT=1 git commit -F msg.txt >x',
    'CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=a*b git commit -F m',
    'CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=$X git commit -F m',
    'CAST_COMMIT_AGENT=1 git commit -m a\tb\nc',
    'CAST_COMMIT_AGENT=1 git commit -F m\n-a',
]

# Accepted or not, an accepted string's argv must equal bash's argv. Includes every
# commit.md-documented shape.
CORPUS = [
    'CAST_COMMIT_AGENT=1 git commit -F msg.txt',
    'CAST_COMMIT_AGENT=1 git commit -F msg.txt > out.log 2>&1',
    'CAST_COMMIT_AGENT=1 git commit -F msg.txt >> out.log 2>&1',
    'CAST_COMMIT_AGENT=1 git commit -F msg.txt 2> err.log',
    'CAST_COMMIT_AGENT=1 git commit -F msg.txt > /dev/null 2>&1',
    'CAST_COMMIT_AGENT=1 git -C repo commit -F msg.txt',
    'CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs git commit -F msg.txt',
    'CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs-only git commit -F msg.txt',
    'CAST_COMMIT_AGENT=1 CAST_HATCH_REASON=why CAST_UNREVIEWED_OK=release.stamp_1 git commit -F m',
    "CAST_COMMIT_AGENT=1 git commit -m 'a|b'",
    'CAST_COMMIT_AGENT=1 git commit -m "a|b"',
    "CAST_COMMIT_AGENT=1 git commit -m 'a b'",
    'CAST_COMMIT_AGENT=1 git commit -m "a b"',
    "CAST_COMMIT_AGENT=1 git commit -m 'a;b'",
    'CAST_COMMIT_AGENT=1 git commit -m "a;b"',
    "CAST_COMMIT_AGENT=1 git commit -m 'a # b'",
    'CAST_COMMIT_AGENT=1 git commit -m "a # b"',
    "CAST_COMMIT_AGENT=1 git commit -m 'x!y'",
    'CAST_COMMIT_AGENT=1 git commit -m "x!y"',
    "CAST_COMMIT_AGENT=1 git commit -m 'a $X `b` \\c'",
    'CAST_COMMIT_AGENT=1 git commit -m "a * ? [ ] { } ~"',
    'CAST_COMMIT_AGENT=1 git commit --message=\'it\'"\'"\'s\'',
    'CAST_COMMIT_AGENT=1 git commit --message=abc',
    'CAST_COMMIT_AGENT=1 git commit --message abc',
    'CAST_COMMIT_AGENT=1 git commit --file=msg.txt',
    "CAST_COMMIT_AGENT=1 git commit -F 'msg file.txt'",
    'CAST_COMMIT_AGENT=1 git commit -q -s --no-edit --amend --allow-empty -F msg.txt',
    'CAST_COMMIT_AGENT=1 git commit --quiet --signoff --verbose -v -F msg.txt',
    'CAST_COMMIT_AGENT=1 git commit --cleanup=strip -F msg.txt',
    "CAST_COMMIT_AGENT=1 git commit --author='A B <a@b.c>' -F msg.txt",
    'CAST_COMMIT_AGENT=1 git commit --date=2026-01-01 -F msg.txt',
    'CAST_COMMIT_AGENT=1 git commit -S -F msg.txt',
    'CAST_COMMIT_AGENT=1 git commit --gpg-sign=ABC -F msg.txt',
    'CAST_COMMIT_AGENT=1 git commit --no-gpg-sign -F msg.txt',
    "CAST_COMMIT_AGENT=1 git commit -m ''",
    "CAST_COMMIT_AGENT=1 git commit -m 'a  b'",
    'CAST_COMMIT_AGENT=1 git commit -m a\'b\'"c"',
    'CAST_COMMIT_AGENT=1 git commit -m a > out2.log',
    'CAST_COMMIT_AGENT=1 git commit -m -x',
    'CAST_COMMIT_AGENT=1   git   commit    -F    msg.txt',
] + MUST_REJECT


def _redirect_free_args(toks):
    """argv the shell passes to the `git` function: tokens after `git`, minus redirects."""
    i = 0
    while i < len(toks) and '=' in toks[i] and toks[i].split('=', 1)[0].replace('_', 'a').isalnum():
        i += 1
    assert toks[i] == 'git'
    out, i = [], i + 1
    while i < len(toks):
        if toks[i] == '2>&1':
            i += 1
        elif toks[i] in ('>', '>>', '2>', '2>>'):
            i += 2
        else:
            out.append(toks[i])
            i += 1
    return out


class TestShellDifferential(GuardGateCase):
    def shell_argv(self, argv0, seg, cwd):
        script = "exec 3>&1; git(){ printf '<%s>' \"$@\" >&3; }; " + seg
        r = subprocess.run(argv0 + [script], cwd=cwd, capture_output=True, text=True, timeout=20)
        return r.stdout

    def bash_argv(self, seg, cwd):
        return self.shell_argv(['bash', '-c'], seg, cwd)

    @unittest.skipUnless(shutil.which('zsh'), 'zsh not installed')
    def test_accepted_strings_have_zsh_identical_argv(self):
        import shlex
        work = os.path.join(self.tmp, 'zwork')
        os.makedirs(work)
        accepted = 0
        for seg in CORPUS:
            target, why = guard._review_gate_shape(seg, work)
            if target is None:
                continue
            accepted += 1
            expected = ''.join(f'<{a}>' for a in _redirect_free_args(shlex.split(seg)))
            with self.subTest(seg=seg):
                self.assertEqual(
                    self.shell_argv(['zsh', '-f', '-o', 'extendedglob', '-c'], seg, work), expected, seg)
        self.assertGreaterEqual(accepted, 30)

    def test_pipeline_siblings_are_unverifiable(self):
        self.enforce()
        self.seed()
        for cmd in ('CAST_COMMIT_AGENT=1 git commit -F msg.txt | git add -A',
                    'CAST_COMMIT_AGENT=1 git commit -F msg.txt |& cat',
                    'CAST_COMMIT_AGENT=1 git commit -F msg.txt | cat',
                    'cat x | CAST_COMMIT_AGENT=1 git commit -F msg.txt'):
            with self.subTest(cmd=cmd):
                self.assertGateBlock(cmd)

    MULTI_LINE = (
        # an apostrophe in a comment is not a quote to bash, but opens one in a naive scan
        "CAST_COMMIT_AGENT=1 git commit -F msg.txt # it's\ncat x | git add -A",
        # same through a heredoc body
        "CAST_COMMIT_AGENT=1 git commit -F msg.txt\ncat <<EOF\nit's\nEOF\nx | git add -A",
        'CAST_COMMIT_AGENT=1 git commit -F msg.txt\r\ngit add -A',
        'CAST_COMMIT_AGENT=1 git commit -F msg.txt\necho done',
    )

    def test_multi_line_commands_are_unverifiable_in_enforce(self):
        self.enforce()
        self.seed()
        for cmd in self.MULTI_LINE:
            with self.subTest(cmd=cmd):
                self.assertGateBlock(cmd)
        self.assertIn('multi-line', self.rows()[0]['reasons'])

    def test_multi_line_commands_allowed_and_logged_in_warn(self):
        for n, cmd in enumerate(self.MULTI_LINE, 1):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.ev(cmd)[0], 0)
                self.assertEqual(len(self.rows()), n)
                self.assertIn('multi-line', self.rows()[-1]['reasons'])

    def test_quoted_pipe_and_or_list_are_not_pipelines(self):
        self.enforce()
        self.seed()
        for cmd in ("CAST_COMMIT_AGENT=1 git commit -F msg.txt && echo 'a|b'",
                    'CAST_COMMIT_AGENT=1 git commit -F msg.txt || true'):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.ev(cmd), (0, None), cmd)

    def test_pipeline_warn_allows_and_logs(self):
        p = mock.patch.object(guard, '_REVIEW_GATE_MODE', 'warn')
        p.start()
        self.addCleanup(p.stop)
        self.assertEqual(self.ev('CAST_COMMIT_AGENT=1 git commit -F msg.txt | cat')[0], 0)
        self.assertIn('pipeline', self.rows()[0]['reasons'])

    def test_redirect_into_home_dot_claude_is_unverifiable(self):
        self.enforce()
        self.seed()
        for target in (f'{self.home}/.claude/cast.db', f'{self.home}/.claude/state/x'):
            with self.subTest(target=target):
                self.assertGateBlock(f'CAST_COMMIT_AGENT=1 git commit -F msg.txt > {target}')

    def test_corpus_size(self):
        self.assertGreaterEqual(len(CORPUS), 40)

    def test_must_reject_are_unverifiable(self):
        for seg in MUST_REJECT:
            with self.subTest(seg=seg):
                target, why = guard._review_gate_shape(seg, self.repo)
                self.assertIsNone(target, seg)

    def test_must_reject_block_in_enforce(self):
        self.enforce()
        self.seed()
        for seg in MUST_REJECT:
            if '\n' in seg:
                continue   # the guard splits lines into separate segments; the shape fn is tested above
            with self.subTest(seg=seg):
                code, msg = self.ev(seg)
                self.assertEqual(code, 2, seg)

    def test_accepted_strings_have_bash_identical_argv(self):
        import shlex
        work = os.path.join(self.tmp, 'work')
        os.makedirs(work)
        accepted = 0
        for seg in CORPUS:
            target, why = guard._review_gate_shape(seg, work)
            if target is None:
                continue
            accepted += 1
            expected = ''.join(f'<{a}>' for a in _redirect_free_args(shlex.split(seg)))
            with self.subTest(seg=seg):
                self.assertEqual(self.bash_argv(seg, work), expected, seg)
        self.assertGreaterEqual(accepted, 30)   # a shape that rejects everything proves nothing

    def test_documented_shapes_are_accepted(self):
        for seg in CORPUS[:9]:
            with self.subTest(seg=seg):
                self.assertIsNotNone(guard._review_gate_shape(seg, self.repo)[0], seg)


class TestDocumentedShapes(GuardGateCase):
    """Every command shape agents/core/commit.md documents must pass the guard."""

    def shapes(self):
        return [
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt',
            f'CAST_COMMIT_AGENT=1 git -C {self.repo} commit -F msg.txt',
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt && git log -1 --oneline',
            # commit.md step 7 capture form
            'CAST_COMMIT_AGENT=1 git commit -F msg.txt > out.log 2>&1; rc=$?; tail -100 out.log',
            f'CAST_COMMIT_AGENT=1 git commit -F msg.txt >> {self.tmp}/out.log 2>&1',
        ]

    def test_allowed_under_warn(self):
        for cmd in self.shapes() + ['CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs git commit -F msg.txt']:
            with self.subTest(cmd=cmd):
                self.assertEqual(self.ev(cmd)[0], 0)

    def test_allowed_under_enforce_when_approved(self):
        self.enforce()
        self.seed()
        for cmd in self.shapes():
            with self.subTest(cmd=cmd):
                self.assertEqual(self.ev(cmd)[0], 0)

    def test_commit_md_step7_example_is_verifiable(self):
        """The exact step-7 command in commit.md, placeholders filled with real paths."""
        md = (Path(__file__).parent.parent / 'agents' / 'core' / 'commit.md').read_text()
        lines = [ln.strip() for ln in md.splitlines()
                 if ln.strip().startswith('CAST_COMMIT_AGENT=1 git commit -F <msg-file> >')]
        self.assertEqual(len(lines), 1, lines)
        cmd = lines[0].replace('<msg-file>', os.path.join(self.repo, 'msg.txt')) \
                      .replace('<log-path>', os.path.join(self.tmp, 'cast-commit.AbC123'))
        self.enforce()
        self.seed()
        self.assertEqual(self.ev(cmd), (0, None), cmd)
        (row,) = self.rows()
        self.assertEqual((row['would_block'], row['source'], row['mode']), (0, 'guard', 'enforce'))

    def test_commit_md_step7_with_dash_C_is_verifiable(self):
        self.enforce()
        self.seed()
        self.cd(self.tmp)
        cmd = (f'CAST_COMMIT_AGENT=1 git -C {self.repo} commit -F {self.repo}/msg.txt '
               f'> {self.tmp}/cast-commit.AbC123 2>&1; rc=$?; echo "commit rc=$rc"')
        self.assertEqual(self.ev(cmd), (0, None), cmd)

    def test_hatch_shape_allowed_under_enforce_when_unreviewed(self):
        self.enforce()
        self.assertEqual(self.ev('CAST_COMMIT_AGENT=1 CAST_UNREVIEWED_OK=docs git commit -F msg.txt')[0], 0)


if __name__ == '__main__':
    unittest.main()
