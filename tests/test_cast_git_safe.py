#!/usr/bin/env python3
"""Tests for scripts/cast_git_safe.py -- Python wrapper over the bash cast_git_safe primitive.

Every hardening claim is proven with a CONTROL: the same canary fires under plain git (or plain
bash) and does NOT fire through cast_git_safe.run(). A canary that never fires proves nothing.

HOME is redirected to an isolated temp dir and inherited GIT_* variables are dropped for every
test, so the real ~/.gitconfig and any surrounding git hook environment never leak in.
"""
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_git_safe  # noqa: E402

_IDENT = ['-c', 'user.email=test@example.com', '-c', 'user.name=t', '-c', 'commit.gpgsign=false']


class GitSafeTestBase(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = os.path.realpath(tmp.name)
        home = os.path.join(self.root, 'home')
        os.mkdir(home)
        env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        env.update({'HOME': home, 'XDG_CONFIG_HOME': os.path.join(home, '.config'),
                    'GIT_CONFIG_NOSYSTEM': '1'})
        env.pop('BASH_ENV', None)
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.canaries = os.path.join(self.root, 'canaries')
        os.mkdir(self.canaries)
        self.marker = os.path.join(self.root, 'MARKER')
        self.repo = self._init_repo('repo')

    # -- helpers --------------------------------------------------------------------------
    def git(self, repo: str, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(['git', '-C', repo, *args], env=dict(os.environ),
                              capture_output=True, text=True, check=True, stdin=subprocess.DEVNULL)

    def _init_repo(self, name: str) -> str:
        repo = os.path.join(self.root, name)
        os.mkdir(repo)
        self._seed(repo)
        return repo

    def _seed(self, repo: str) -> None:
        self.git(repo, 'init', '-q')
        Path(repo, 'a.txt').write_text('a\n')
        self.git(repo, 'add', 'a.txt')
        self.git(repo, *_IDENT, 'commit', '-q', '-m', 'init')

    def script(self, name: str, body: str) -> str:
        path = os.path.join(self.canaries, name)
        Path(path).write_text(f'#!/bin/sh\n{body}\n')
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        return path

    def canary(self, name: str = 'canary.sh') -> str:
        return self.script(name, f'touch "{self.marker}"')

    def fired(self) -> bool:
        return os.path.exists(self.marker)

    def reset_marker(self) -> None:
        if os.path.exists(self.marker):
            os.remove(self.marker)

    def shim_path(self, git_body: str) -> str:
        """PATH with a fake `git` first; returns the new PATH value."""
        shim = os.path.join(self.root, 'shim')
        os.makedirs(shim, exist_ok=True)
        path = os.path.join(shim, 'git')
        Path(path).write_text(f'#!/bin/sh\n{git_body}\n')
        os.chmod(path, 0o755)
        return shim + os.pathsep + os.environ['PATH']


class RunBehaviour(GitSafeTestBase):
    def test_01_benign_repo_runs_git(self) -> None:
        r = cast_git_safe.run(self.repo, ['rev-parse', '--show-toplevel'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.path.realpath(r.stdout.strip()), os.path.realpath(self.repo))

    def test_02_fsmonitor_canary_neutralised(self) -> None:
        self.git(self.repo, 'config', 'core.fsmonitor', self.canary())
        Path(self.repo, 'new.txt').write_text('x\n')
        # CONTROL: plain git status runs the fsmonitor hook.
        self.git(self.repo, 'status', '--porcelain')
        self.assertTrue(self.fired(), 'control: plain git status did not fire the fsmonitor canary')
        self.reset_marker()
        r = cast_git_safe.run(self.repo, ['status', '--porcelain'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('new.txt', r.stdout, 'git did not actually run (vacuous pass)')
        self.assertFalse(self.fired(), 'fsmonitor canary fired through cast_git_safe.run')

    def test_03_config_hook_canary_neutralised(self) -> None:
        canary = self.canary()
        self.git(self.repo, 'config', 'hook.x.event', 'reference-transaction')
        self.git(self.repo, 'config', 'hook.x.command', canary)
        self.git(self.repo, 'branch', 'b2')
        self.git(self.repo, 'branch', 'b3')
        # CONTROL (attempt-first): needs git >= 2.54 config-based hooks.
        self.git(self.repo, 'branch', '-d', '--', 'b2')
        if not self.fired():
            self.skipTest('git too old for config-based hooks (hook.<name>.command); control did not fire')
        self.reset_marker()
        r = cast_git_safe.run(self.repo, ['branch', '-d', '--', 'b3'])
        self.assertEqual(r.returncode, 0, r.stderr)
        branches = self.git(self.repo, 'branch', '--list', 'b3').stdout.strip()
        self.assertEqual(branches, '', 'b3 still exists: git did not actually run (vacuous pass)')
        self.assertFalse(self.fired(), 'config-hook canary fired through cast_git_safe.run')

    def test_04_leading_option_rejected(self) -> None:
        r = cast_git_safe.run(self.repo, ['-c', 'x=y', 'status'])
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, '')

    def test_05_missing_lib_returns_3_and_runs_nothing(self) -> None:
        path = self.shim_path(f'touch "{self.marker}"\nexit 1')
        with mock.patch.dict(os.environ, {'PATH': path}):
            # CONTROL: with the real lib the shimmed git IS reached.
            cast_git_safe.run(self.repo, ['status'])
            self.assertTrue(self.fired(), 'control: shimmed git was never reached with the real lib')
            self.reset_marker()
            with mock.patch.object(cast_git_safe, 'LIB', os.path.join(self.root, 'no-such-lib.sh')):
                r = cast_git_safe.run(self.repo, ['status'])
        self.assertEqual(r.returncode, 3)
        self.assertEqual(r.stdout, '')
        self.assertFalse(self.fired(), 'something ran despite the missing lib')
        self.assertEqual(cast_git_safe._BASH, '/bin/bash')  # absolute: PATH shim cannot swap it

    def test_05b_lib_that_is_a_directory_returns_3(self) -> None:
        with mock.patch.object(cast_git_safe, 'LIB', self.canaries):
            r = cast_git_safe.run(self.repo, ['status'])
        self.assertEqual(r.returncode, 3)

    def test_06_bash_env_is_not_inherited(self) -> None:
        bash_env = self.script('bashenv.sh', f'touch "{self.marker}"')
        with mock.patch.dict(os.environ, {'BASH_ENV': bash_env}):
            # CONTROL: an inherited BASH_ENV DOES execute in a plain non-interactive bash.
            subprocess.run(['/bin/bash', '-c', 'true'], env={**os.environ}, check=True)
            self.assertTrue(self.fired(), 'control: BASH_ENV did not fire for plain bash')
            self.reset_marker()
            r = cast_git_safe.run(self.repo, ['rev-parse', '--show-toplevel'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.fired(), 'BASH_ENV script executed through cast_git_safe.run')

    def test_06b_popen_call_shape(self) -> None:
        """Structural: argv list, no shell, no stdin, bash-exec variables stripped."""
        hostile = {'BASH_ENV': '/x', 'ENV': '/x', 'SHELLOPTS': 'xtrace', 'BASHOPTS': 'x',
                   'PS4': '$(id)', 'BASH_FUNC_source%%': '() { :; }', 'KEEP_ME': '1'}
        with mock.patch.dict(os.environ, hostile):
            with mock.patch.object(cast_git_safe.subprocess, 'Popen',
                                   wraps=cast_git_safe.subprocess.Popen) as popen:
                cast_git_safe.run(self.repo, ['rev-parse', 'HEAD'])
        (argv,), kw = popen.call_args
        self.assertEqual(argv[:3], ['/bin/bash', '-c', cast_git_safe._SCRIPT])
        self.assertEqual(argv[3:], ['cast_git_safe', cast_git_safe.LIB, self.repo, 'rev-parse', 'HEAD'])
        self.assertFalse(kw.get('shell', False))
        self.assertEqual(kw['stdin'], subprocess.DEVNULL)
        self.assertEqual(kw['env'].get('KEEP_ME'), '1')
        for name in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS', 'PS4', 'BASH_FUNC_source%%'):
            self.assertNotIn(name, kw['env'])

    def test_07_repo_dir_is_argv_not_interpolated(self) -> None:
        name = 'my repo $(touch $CAST_TEST_MARKER) `touch $CAST_TEST_MARKER` ; x'
        repo = self._init_repo(name)
        with mock.patch.dict(os.environ, {'CAST_TEST_MARKER': self.marker}):
            # CONTROL: interpolating the same name into a shell string DOES run the payload.
            subprocess.run(['/bin/bash', '-c', f'true {name}'], env={**os.environ},
                           stderr=subprocess.DEVNULL, check=False)
            self.assertTrue(self.fired(), 'control: the directory name is not a live payload')
            self.reset_marker()
            r = cast_git_safe.run(repo, ['rev-parse', '--show-toplevel'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.path.realpath(r.stdout.strip()), os.path.realpath(repo))
        self.assertFalse(self.fired(), 'command substitution in repo_dir executed')

    def test_08_timeout_returns_124_and_reaps_group(self) -> None:
        # The config-enumeration call returns at once; the real git call sleeps while holding
        # the captured stdout/stderr pipes (so killing only bash would block communicate()).
        pidfile = os.path.join(self.root, 'sleeper.pid')
        path = self.shim_path(
            f'case "$*" in *--get-regexp*) exit 1;; esac\necho $$ > "{pidfile}"\nexec sleep 30')
        with mock.patch.dict(os.environ, {'PATH': path}):
            start = time.monotonic()
            r = cast_git_safe.run(self.repo, ['status'], timeout=1)
            elapsed = time.monotonic() - start
        self.assertTrue(os.path.exists(pidfile), 'the sleeping git shim was never reached')
        pid = int(Path(pidfile).read_text().strip())
        self.addCleanup(lambda: self._kill_quietly(pid))
        self.assertEqual(r.returncode, 124)
        self.assertEqual(r.stdout, '')
        self.assertLess(elapsed, 10, f'timeout did not return promptly ({elapsed:.1f}s)')
        # The descendant must be dead, not merely abandoned (reparented orphans are reaped fast).
        deadline = time.monotonic() + 3
        while self._alive(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(self._alive(pid), 'timed-out git descendant was left running')

    @staticmethod
    def _alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    @staticmethod
    def _kill_quietly(pid: int) -> None:
        try:
            os.kill(pid, 9)
        except OSError:
            pass

    def test_09_failed_hardening_read_is_nonzero(self) -> None:
        Path(self.repo, '.git', 'config').write_text('[broken\n')
        r = cast_git_safe.run(self.repo, ['status', '--porcelain'])
        self.assertEqual(r.returncode, 3)
        self.assertEqual(r.stdout, '')

    def test_10_bad_argument_types_raise(self) -> None:
        with self.assertRaises(TypeError):
            cast_git_safe.run(123, ['status'])  # type: ignore[arg-type]
        with self.assertRaises(TypeError):
            cast_git_safe.run(self.repo, 'status')  # type: ignore[arg-type]
        with self.assertRaises(TypeError):
            cast_git_safe.run(self.repo, ['status', 1])  # type: ignore[list-item]


if __name__ == '__main__':
    unittest.main()
