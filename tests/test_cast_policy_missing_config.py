#!/usr/bin/env python3
"""A missing INSTALLED ~/.claude/config/policies.json fails closed -- but only when the
guard itself runs from the installed ~/.claude/scripts dir.

`_policy_evaluate` used to return (0, None) on any missing config, so deleting
~/.claude/config/policies.json silently disabled every block policy on an installed
CAST. The guard now distinguishes WHERE it runs from (`_running_from_installed_scripts`):

  * loaded from $HOME/.claude/scripts  -> CAST is installed; a missing config is
    deletion/corruption -> (2, msg); CAST_POLICY_OVERRIDE=1 bypasses (audit-logged as
    `policies-config-missing`).
  * loaded from anywhere else (the Claude Code plugin's ${CLAUDE_PLUGIN_ROOT}/scripts,
    a repo checkout) -> plugin users never receive ~/.claude/config/policies.json, so a
    missing config stays (0, None).

What a passing check looks like while the bug is present: the "installed + missing ->
blocked" test asserts code == 2 AND `bash install.sh` in the message, so it fails against
the old unconditional `return 0, None`. The "not installed -> allowed" tests would pass
under the old code too; they exist to pin the plugin/checkout carve-out so a future
"always fail closed" simplification is caught.

Every test runs against a temp HOME (HOME patched so expanduser resolves into it); the
guard under test is a COPY loaded from a temp dir, never the real ~/.claude/scripts.
The guard imports stdlib only, so no sibling modules are copied.
"""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent
_GUARD_SRC = _REPO / 'scripts' / 'cast-git-guard.py'
_POLICIES = _REPO / 'config' / 'policies.json'

SESS = 'sess-missing-cfg-1'
# Matches no policy in the repo config, so a present+valid config returns (0, None).
BENIGN_PATH = '/tmp/x/app.py'

_counter = [0]


def _load_guard_from(directory):
    """Copy the guard into `directory` and load it from THERE (so __file__ points at the
    copy -- the same way the dispatcher's spec_from_file_location + exec_module does)."""
    os.makedirs(directory, exist_ok=True)
    dest = os.path.join(directory, 'cast-git-guard.py')
    shutil.copy(str(_GUARD_SRC), dest)
    _counter[0] += 1
    spec = importlib.util.spec_from_file_location(f'cast_git_guard_missingcfg_{_counter[0]}', dest)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Base(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-missingcfg-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        self.installed_scripts = os.path.join(self.home, '.claude', 'scripts')
        self.config_dir = os.path.join(self.home, '.claude', 'config')
        self.audit_path = os.path.join(self.home, '.claude', 'logs', 'audit.jsonl')
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SESSION_ID', 'CLAUDE_DIR'):
            os.environ.pop(k, None)
        # Hard safety: never operate on a real home.
        self.assertTrue(self.home.startswith(os.path.realpath(tempfile.gettempdir())))
        self.assertEqual(os.path.expanduser('~'), self.home)

    def seed_config(self):
        os.makedirs(self.config_dir, exist_ok=True)
        shutil.copy(str(_POLICIES), os.path.join(self.config_dir, 'policies.json'))

    def audit_events(self):
        if not os.path.exists(self.audit_path):
            return []
        with open(self.audit_path) as f:
            return [json.loads(line) for line in f if line.strip()]


class TestInstalledGuardMissingConfig(_Base):
    def test_installed_and_config_missing_blocks(self):
        gg = _load_guard_from(self.installed_scripts)
        self.assertFalse(os.path.exists(os.path.join(self.config_dir, 'policies.json')))
        code, msg = gg._policy_evaluate(BENIGN_PATH, SESS)
        self.assertEqual(code, 2)
        self.assertIn('[CAST-POLICY-BLOCK]', msg)
        self.assertIn('bash install.sh', msg)
        self.assertIn('~/.claude/config/policies.json', msg)
        self.assertIn(BENIGN_PATH, msg)
        self.assertIn('CAST_POLICY_OVERRIDE=1', msg)

    def test_installed_and_config_missing_caps_file_path_at_256(self):
        gg = _load_guard_from(self.installed_scripts)
        long_path = '/tmp/x/' + ('a' * 600) + '.py'
        code, msg = gg._policy_evaluate(long_path, SESS)
        self.assertEqual(code, 2)
        self.assertIn(long_path[:256], msg)
        self.assertNotIn(long_path[:257], msg)

    def test_installed_missing_with_override_allows_and_audits(self):
        gg = _load_guard_from(self.installed_scripts)
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            code, msg = gg._policy_evaluate(BENIGN_PATH, SESS)
        self.assertEqual((code, msg), (0, None))
        events = [e for e in self.audit_events() if e.get('policy_id') == 'policies-config-missing']
        self.assertEqual(len(events), 1, self.audit_events())
        self.assertEqual(events[0]['event'], 'POLICY_OVERRIDE')
        self.assertEqual(events[0]['file_path'], BENIGN_PATH)
        self.assertEqual(events[0]['session_id'], SESS)

    def test_installed_missing_override_must_be_exactly_1(self):
        gg = _load_guard_from(self.installed_scripts)
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': 'true'}):
            code, _msg = gg._policy_evaluate(BENIGN_PATH, SESS)
        self.assertEqual(code, 2)
        self.assertEqual(self.audit_events(), [])

    def test_installed_dangling_symlink_config_is_invalid_not_missing(self):
        # lstat succeeds on a dangling symlink -> 'invalid' path (existing behaviour),
        # distinct wording from the new 'missing' message. Pins that the new branch did
        # not swallow the invalid-config handling.
        gg = _load_guard_from(self.installed_scripts)
        os.makedirs(self.config_dir)
        os.symlink(os.path.join(self.home, 'nowhere.json'),
                   os.path.join(self.config_dir, 'policies.json'))
        code, msg = gg._policy_evaluate(BENIGN_PATH, SESS)
        self.assertEqual(code, 2)
        self.assertIn('unreadable or malformed', msg)
        self.assertNotIn('bash install.sh', msg)

    def test_installed_and_config_present_is_unchanged(self):
        gg = _load_guard_from(self.installed_scripts)
        self.seed_config()
        self.assertEqual(gg._policy_evaluate(BENIGN_PATH, SESS), (0, None))
        self.assertEqual(self.audit_events(), [])


class TestNonInstalledGuardMissingConfig(_Base):
    def test_plugin_style_dir_missing_config_allows(self):
        plugin_scripts = os.path.join(self.home, 'plugin-cache', 'cast', 'scripts')
        gg = _load_guard_from(plugin_scripts)
        self.assertEqual(gg._policy_evaluate(BENIGN_PATH, SESS), (0, None))
        self.assertEqual(self.audit_events(), [])

    def test_repo_checkout_import_missing_config_allows(self):
        spec = importlib.util.spec_from_file_location('cast_git_guard_missingcfg_repo', str(_GUARD_SRC))
        gg = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gg)
        self.assertEqual(gg._policy_evaluate(BENIGN_PATH, SESS), (0, None))

    def test_installed_check_is_evaluated_at_call_time_not_import(self):
        # Loaded from home A's installed scripts dir, then HOME flips to an empty home B:
        # the guard is no longer the installed one for B -> allow. Proves no import-time cache.
        gg = _load_guard_from(self.installed_scripts)
        self.assertTrue(gg._running_from_installed_scripts())
        other = os.path.realpath(tempfile.mkdtemp(prefix='cast-missingcfg-home-b-'))
        self.addCleanup(shutil.rmtree, other, True)
        with mock.patch.dict(os.environ, {'HOME': other}):
            self.assertFalse(gg._running_from_installed_scripts())
            self.assertEqual(gg._policy_evaluate(BENIGN_PATH, SESS), (0, None))

    def test_symlinked_scripts_dir_resolves_to_installed(self):
        # ~/.claude/scripts may be a symlink to a checkout; realpath on both sides must agree.
        real_dir = os.path.join(self.home, 'elsewhere', 'scripts')
        gg = _load_guard_from(real_dir)
        os.makedirs(os.path.join(self.home, '.claude'), exist_ok=True)
        os.symlink(real_dir, self.installed_scripts)
        self.assertTrue(gg._running_from_installed_scripts())
        code, msg = gg._policy_evaluate(BENIGN_PATH, SESS)
        self.assertEqual(code, 2)
        self.assertIn('bash install.sh', msg)


class TestRunningFromInstalledScriptsFailsClosed(_Base):
    def test_exception_while_computing_returns_true(self):
        gg = _load_guard_from(os.path.join(self.home, 'plugin-cache', 'scripts'))
        self.assertFalse(gg._running_from_installed_scripts())
        with mock.patch.object(gg.os.path, 'realpath', side_effect=OSError('boom')):
            self.assertTrue(gg._running_from_installed_scripts())


if __name__ == '__main__':
    unittest.main()
