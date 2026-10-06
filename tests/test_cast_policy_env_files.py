#!/usr/bin/env python3
"""Live probe of the `env-files-require-security` policy (config/policies.json) through
scripts/cast-git-guard.py `_policy_evaluate` / `evaluate`.

The policy (`path_pattern` `.*\\.env(\\..*)?$`, requires_agent `security`, severity
`block`) had never been exercised end to end: the repo's other policy tests use the
workflows policy. This drives the REAL repo config, installed into an isolated temp HOME
at $HOME/.claude/config/policies.json (the only place the guard reads), with NO security
completion record present.

What a passing check looks like while the policy is broken: every BLOCKED assertion
checks for the policy id in the message, not just exit code 2, because a malformed or
unreadable config also fails closed with code 2 (`failing closed`, no policy id). A
policy whose regex stopped matching returns (0, None) and fails the BLOCKED cases; a
config that silently went missing also returns (0, None), which the positive
`test_installed_config_carries_the_env_policy` + the BLOCKED cases would expose.

Hyphenated filename cannot be imported normally -- load via importlib, same pattern as
tests/test_cast_git_guard_status_gate.py. Path literals are /home/... only (never a real
user directory).
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
_SCRIPT_PATH = _REPO / 'scripts' / 'cast-git-guard.py'
_POLICIES = _REPO / 'config' / 'policies.json'

_spec = importlib.util.spec_from_file_location('cast_git_guard_env_files', str(_SCRIPT_PATH))
gg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gg)

POLICY_ID = 'env-files-require-security'
SESS = 'sess-env-1'

BLOCKED = (
    '/home/u/p/.env',
    '/home/u/p/.env.production',
    '/home/u/p/.env.development.local',
    '/home/u/p/sub/.env.local',
    '/home/u/p/app.env',
)
# `environment.py` shares the `env` prefix but has no `.env` token; `.envrc` is direnv
# shell code that executes on `cd` and is currently NOT covered (see test below).
ALLOWED = (
    '/home/u/p/environment.py',
    '/home/u/p/.envrc',
    '/home/u/p/README.md',
)


class _Base(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-envpol-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        self.status_dir = os.path.join(self.home, '.claude', 'agent-status')
        os.makedirs(self.status_dir)
        cfg = os.path.join(self.home, '.claude', 'config')
        os.makedirs(cfg)
        shutil.copy(str(_POLICIES), os.path.join(cfg, 'policies.json'))
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SESSION_ID', 'CLAUDE_DIR'):
            os.environ.pop(k, None)

    def record(self, agent_type, status='DONE', sess=SESS):
        path = os.path.join(self.status_dir, f'{agent_type}-1.json')
        with open(path, 'w') as f:
            json.dump({'agent': agent_type, 'status': status, 'session_id': sess,
                       'agent_type': agent_type}, f)


class TestEnvFilesRequireSecurity(_Base):
    def test_installed_config_carries_the_env_policy(self):
        with open(os.path.join(self.home, '.claude', 'config', 'policies.json')) as f:
            policies = {p['id']: p for p in json.load(f)['policies']}
        self.assertIn(POLICY_ID, policies)
        p = policies[POLICY_ID]
        self.assertEqual(p['requires_agent'], 'security')
        self.assertEqual(p['severity'], 'block')

    def test_env_files_are_blocked_without_a_security_record(self):
        for path in BLOCKED:
            with self.subTest(path=path):
                code, msg = gg._policy_evaluate(path, SESS)
                self.assertEqual(code, 2, msg)
                self.assertIn(f'Policy "{POLICY_ID}"', msg)

    def test_non_env_paths_are_not_blocked(self):
        for path in ALLOWED:
            with self.subTest(path=path):
                code, msg = gg._policy_evaluate(path, SESS)
                self.assertEqual((code, msg), (0, None))

    def test_envrc_is_currently_not_covered(self):
        # PINS current behaviour, not desired behaviour: `.envrc` (direnv) executes
        # arbitrary shell on `cd` yet falls outside `.*\.env(\..*)?$`. Changing the
        # policy is a separate decision; if it is widened, flip this assertion.
        self.assertEqual(gg._policy_evaluate('/home/u/p/.envrc', SESS), (0, None))

    def test_a_passing_security_record_unblocks_exactly_this_session(self):
        self.record('security', 'DONE')
        for path in BLOCKED:
            with self.subTest(path=path):
                self.assertEqual(gg._policy_evaluate(path, SESS), (0, None))
        # A different session, an empty session and a record of another type stay blocked.
        code, msg = gg._policy_evaluate('/home/u/p/.env.production', 'other-sess')
        self.assertEqual(code, 2, msg)
        code, msg = gg._policy_evaluate('/home/u/p/.env.production', '')
        self.assertEqual(code, 2, msg)

    def test_a_non_security_record_does_not_unblock(self):
        self.record('devops', 'DONE')
        code, msg = gg._policy_evaluate('/home/u/p/.env.production', SESS)
        self.assertEqual(code, 2, msg)
        self.assertIn(f'Policy "{POLICY_ID}"', msg)

    def test_a_blocked_security_record_does_not_unblock(self):
        self.record('security', 'BLOCKED')
        code, msg = gg._policy_evaluate('/home/u/p/.env.production', SESS)
        self.assertEqual(code, 2, msg)

    def test_write_and_edit_tools_route_through_the_policy(self):
        for tool in ('Write', 'Edit'):
            with self.subTest(tool=tool):
                code, msg = gg.evaluate(tool, {'file_path': '/home/u/p/.env.local'}, SESS)
                self.assertEqual(code, 2, msg)
                self.assertIn(f'Policy "{POLICY_ID}"', msg)


if __name__ == '__main__':
    unittest.main()
