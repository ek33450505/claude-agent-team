#!/usr/bin/env python3
"""U6c-2: the `warn`-severity secret-path policies in config/policies.json.

`credentials-files-warn`, `secrets-files-warn` and `auth-dirs-outside-src-warn` flag file-tool
writes to credential/secret files and to `auth/` directories outside `src/auth/` (which
`auth-requires-security` already BLOCKS). They are warn-only: they must never block.

IMPORTANT (reported to the orchestrator): scripts/cast-git-guard.py `_policy_evaluate` currently
treats a matching `warn` policy as "allow silently" -- it returns (0, None) with no
additionalContext. So today these entries are declarative: valid, loaded, matched, never
blocking, but not yet SURFACED to the model. Surfacing needs an engine change (out of scope for
this unit). The tests below therefore pin (a) the regexes fire / do not fire on the right
paths, exactly as the engine applies them (re.search, IGNORECASE, raw + resolved path), and
(b) the engine still returns (0, None) -- never a block -- for every matching path with no
security record, and the existing .env policy and its template exemptions still hold.

Near-miss decisions (documented, pinned):
  * `credential_utils.py` / `credentials` as a DIRECTORY name are NOT matched: the pattern keys
    on the file's own name, and singular `credential` is a different token.
  * `secrets.py`, `secrets_test.py` DO match (`secrets*`): over-warning is the cheap failure
    mode for a warn-only policy. `my_secrets.py` / `secret_santa.py` do not (`*.secrets*` needs
    the dot).
  * `src/auth/` (and `mysrc/auth/`, mirroring the unanchored `src/auth/.*` block policy) is
    excluded from the auth warn -- that path is already blocked.
"""
import importlib.util
import json
import os
import re
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent
_POLICIES = _REPO / 'config' / 'policies.json'
_spec = importlib.util.spec_from_file_location('cast_git_guard_warn', str(_REPO / 'scripts' / 'cast-git-guard.py'))
gg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gg)

SESS = 'sess-warn-1'

FIRES = {
    'credentials-files-warn': (
        'credentials', 'credentials.json', 'credentials.yaml', '/home/u/p/credentials',
        '/home/u/p/sub/credentials.json', '/home/u/p/.aws/credentials',
        '/home/u/p/gcp-credentials.json', '/home/u/p/my_credentials_v2.json',
        '/home/u/p/CREDENTIALS.JSON',
    ),
    'secrets-files-warn': (
        'secrets', 'secrets.yaml', '/home/u/p/secrets.json', '/home/u/p/secrets',
        '/home/u/p/config/.secrets', '/home/u/p/app.secrets.json', '/home/u/p/.secrets.baseline',
        '/home/u/p/prod.secrets', '/home/u/p/SECRETS.YML',
    ),
    'auth-dirs-outside-src-warn': (
        'auth/login.ts', '/home/u/p/auth/login.ts', '/home/u/p/lib/auth/session.py',
        '/home/u/p/app/auth/x', '/home/u/p/AUTH/x',
    ),
}

NEAR_MISSES = {
    'credentials-files-warn': (
        '/home/u/p/credential_utils.py', '/home/u/p/credentials/loader.py',
        '/home/u/p/credentials_loader.py.d/x.py', '/home/u/p/README.md',
        '/home/u/p/config.json', '/home/u/p/mycredentials.py',
    ),
    'secrets-files-warn': (
        '/home/u/p/secret_santa.py', '/home/u/p/my_secrets.py', '/home/u/p/secrets/loader.py',
        '/home/u/p/src/secret.ts', '/home/u/p/README.md',
    ),
    'auth-dirs-outside-src-warn': (
        '/home/u/p/src/auth/x.ts', 'src/auth/x.ts', '/home/u/p/mysrc/auth/x.ts',
        '/home/u/p/oauth/x.ts', '/home/u/p/authors/x.ts', '/home/u/p/auth.ts',
        '/home/u/p/author/x', '/home/u/p/README.md',
    ),
}


def _policies():
    with open(_POLICIES) as f:
        return {p['id']: p for p in json.load(f)['policies']}


class TestWarnPolicyConfig(unittest.TestCase):
    def test_policies_present_warn_only_and_valid(self):
        pols = _policies()
        for pid in FIRES:
            with self.subTest(policy=pid):
                self.assertIn(pid, pols)
                self.assertEqual(pols[pid]['severity'], 'warn')
                self.assertEqual(pols[pid]['requires_agent'], 'security')
                re.compile(pols[pid]['path_pattern'])

    def test_patterns_fire_on_matching_paths(self):
        pols = _policies()
        for pid, paths in FIRES.items():
            for path in paths:
                with self.subTest(policy=pid, path=path):
                    self.assertTrue(re.search(pols[pid]['path_pattern'], path, re.IGNORECASE))

    def test_patterns_do_not_fire_on_near_misses(self):
        pols = _policies()
        for pid, paths in NEAR_MISSES.items():
            for path in paths:
                with self.subTest(policy=pid, path=path):
                    self.assertFalse(re.search(pols[pid]['path_pattern'], path, re.IGNORECASE))

    def test_hooks_policy_description_is_not_stale(self):
        desc = _policies()['githooks-require-security']['description']
        self.assertNotIn('= core.hooksPath', desc)
        self.assertIn('~/.claude/githooks', desc)


class TestWarnPolicyThroughEngine(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-warnpol-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        os.makedirs(os.path.join(self.home, '.claude', 'agent-status'))
        cfg = os.path.join(self.home, '.claude', 'config')
        os.makedirs(cfg)
        shutil.copy(str(_POLICIES), os.path.join(cfg, 'policies.json'))
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SESSION_ID', 'CLAUDE_DIR'):
            os.environ.pop(k, None)

    def test_matching_paths_never_block_without_a_security_record(self):
        for pid, paths in FIRES.items():
            for path in paths:
                if not path.startswith('/'):
                    continue
                with self.subTest(policy=pid, path=path):
                    code, msg = gg._policy_evaluate(path, SESS)
                    self.assertEqual((code, msg), (0, None))

    def test_existing_block_policies_still_block(self):
        # warn entries must not weaken the block policies or change which policy fires
        for path, pid in (('/home/u/p/src/auth/x.ts', 'auth-requires-security'),
                          ('/home/u/p/.env', 'env-files-require-security'),
                          ('/home/u/p/.env.production', 'env-files-require-security')):
            with self.subTest(path=path):
                code, msg = gg._policy_evaluate(path, SESS)
                self.assertEqual(code, 2, msg)
                self.assertIn(f'Policy "{pid}"', msg)

    def test_env_template_exemptions_still_hold(self):
        for path in ('/home/u/p/.env.example', '/home/u/p/.env.sample', '/home/u/p/.env.template'):
            with self.subTest(path=path):
                self.assertEqual(gg._policy_evaluate(path, SESS), (0, None))


if __name__ == '__main__':
    unittest.main()
