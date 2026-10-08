#!/usr/bin/env python3
"""Unit F part 2: `migrations-require-db-agent` path_pattern is linear and match-equivalent.

The old pattern `.*migrations/.*` is quadratic under re.search (`.*` is retried from every
start offset; measured on a path with no match: 0.69 s at 20 K chars, 17.9 s at 100 K chars, one
Apple-silicon macOS box, CPython 3.14). Under re.search + IGNORECASE the bare literal `migrations/`
has an IDENTICAL match set (the surrounding `.*` could only ever match zero chars or things
that do not affect whether the match exists) and is linear.

Every _policy_evaluate call uses a throw-away HOME holding a copy of the repo's
config/policies.json -- the real ~/.claude is never touched.
"""
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent
_SCRIPTS = _REPO / 'scripts'
_POLICIES = _REPO / 'config' / 'policies.json'
_POLICY_ID = 'migrations-require-db-agent'
_OLD_PATTERN = r'.*migrations/.*'

SAMPLES = [
    'db/migrations/001.sql',
    'foomigrations/x',
    'MIGRATIONS/x',
    'migrations',
    'x/migrations',
    'a/migrationsX/b',
    'migrations/',
    '/migrations/',
    'src/Migrations/2026_01.sql',
    'a\nmigrations/b',
    'migrations\n/x',
    '',
    'README.md',
]


def _policy():
    cfg = json.loads(_POLICIES.read_text(encoding='utf-8'))
    return next(p for p in cfg['policies'] if p['id'] == _POLICY_ID)


def _load_guard():
    sys.path.insert(0, str(_SCRIPTS))
    try:
        spec = importlib.util.spec_from_file_location('cast_git_guard_migpat', str(_SCRIPTS / 'cast-git-guard.py'))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.path.remove(str(_SCRIPTS))


class TestMigrationsPattern(unittest.TestCase):
    def test_shipped_pattern_is_the_bare_literal(self):
        self.assertEqual(_policy()['path_pattern'], 'migrations/')

    def test_equivalent_to_old_pattern_on_samples(self):
        new = re.compile(_policy()['path_pattern'], re.IGNORECASE)
        old = re.compile(_OLD_PATTERN, re.IGNORECASE)
        for path in SAMPLES:
            self.assertEqual(bool(old.search(path)), bool(new.search(path)), repr(path))

    def test_expected_match_set(self):
        new = re.compile(_policy()['path_pattern'], re.IGNORECASE)
        expect = {
            'db/migrations/001.sql': True, 'foomigrations/x': True, 'MIGRATIONS/x': True,
            'migrations': False, 'x/migrations': False, 'a/migrationsX/b': False,
        }
        for path, want in expect.items():
            self.assertEqual(bool(new.search(path)), want, path)

    def test_regex_is_linear_on_100kb_path(self):
        new = re.compile(_policy()['path_pattern'], re.IGNORECASE)
        for path in ('a' * 100_000, 'a/' * 50_000, 'migrations' * 10_000):
            t0 = time.monotonic()
            new.search(path)
            self.assertLess(time.monotonic() - t0, 0.5, path[:12])


class TestPolicyEvaluateTiming(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = _load_guard()

    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-migpat-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        os.makedirs(os.path.join(self.home, '.claude', 'agent-status'))
        os.makedirs(os.path.join(self.home, '.claude', 'config'))
        shutil.copy(str(_POLICIES), os.path.join(self.home, '.claude', 'config', 'policies.json'))
        env = {k: v for k, v in os.environ.items()
               if k not in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SUBPROCESS', 'CLAUDE_SESSION_ID')}
        env['HOME'] = self.home
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_migration_path_still_warns(self):
        code, msg = self.guard._policy_evaluate(os.path.join(self.home, 'proj', 'db', 'migrations', '001.sql'), 'sess-x')
        self.assertEqual(code, 0)
        self.assertIn(_POLICY_ID, msg or '')

    def test_non_migration_path_does_not_warn(self):
        code, msg = self.guard._policy_evaluate(os.path.join(self.home, 'proj', 'db', 'migrationsX', 'a.sql'), 'sess-x')
        self.assertEqual(code, 0)
        self.assertNotIn(_POLICY_ID, msg or '')

    def test_100kb_path_is_blocked_by_length_cap_before_any_regex(self):
        # This does NOT prove the pattern is linear: _policy_evaluate refuses paths over
        # _POLICY_MAX_PATH_LEN (4096) BEFORE any regex runs (exit 2, path-too-long), so it
        # returns fast with the old quadratic pattern too. It shows only that the cap blocks
        # first. The linearity proof is TestMigrationsPattern.test_regex_is_linear_on_100kb_path
        # (direct re.search of the shipped pattern).
        path = os.path.join(self.home, 'a' * 100_000, 'migrations', 'x.sql')
        t0 = time.monotonic()
        code, _ = self.guard._policy_evaluate(path, 'sess-x')
        self.assertLess(time.monotonic() - t0, 1.0)
        self.assertEqual(code, 2)

    def test_longest_allowed_path_is_fast_through_policy_evaluate(self):
        # Just under the cap, the regexes DO run: this is the real worst case.
        pad = self.guard._POLICY_MAX_PATH_LEN - len(self.home) - len('/migrations/x.sql') - 8
        path = os.path.join(self.home, 'a' * pad, 'migrations', 'x.sql')
        self.assertLessEqual(len(path), self.guard._POLICY_MAX_PATH_LEN)
        t0 = time.monotonic()
        code, msg = self.guard._policy_evaluate(path, 'sess-x')
        self.assertLess(time.monotonic() - t0, 1.0)
        self.assertEqual(code, 0)
        self.assertIn(_POLICY_ID, msg or '')


if __name__ == '__main__':
    unittest.main()
