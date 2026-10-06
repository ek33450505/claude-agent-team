#!/usr/bin/env python3
"""Live probe of the `env-files-require-security` policy (config/policies.json) through
scripts/cast-git-guard.py `_policy_evaluate` / `evaluate`.

The policy (`path_pattern`
`.*\\.env(rc(\\..*)?|\\.(?!(?:example|sample|template)$).*)?$`, requires_agent `security`,
severity `block`) covers `.env`, `.env.<anything>`, `<name>.env`, direnv's `.envrc` and
`.envrc.<anything>` (e.g. `.envrc.local`), and EXEMPTS exactly the committed templates `.env.example`,
`.env.sample` and `.env.template` (end of the path). It had never been exercised end to
end: the repo's other policy tests use the workflows policy. This drives the REAL repo config, installed into an isolated temp HOME
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
import time
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
    # Near-miss template names: the exemption is the EXACT final component, nothing more.
    '/home/u/p/.env.example.local',
    '/home/u/p/.env.examples',
    '/home/u/p/.env.sample.bak',
    '/home/u/p/.env.template.old',
    '/home/u/p/.env.example ',          # trailing space
    '/home/u/p/.env.example.',          # trailing dot
    '/home/u/p/.env.example/.env',      # a directory named like a template does not exempt its files
    '/home/u/p/.env.example/secrets',
)
# `.envrc` is direnv shell code that executes on `cd`, and `.envrc.local` is conventionally
# sourced from it (`source_env_if_exists .envrc.local`), so `.envrc` and `.envrc.<anything>`
# are covered. `environment.py` shares the `env` prefix but has no `.env` token.
ENVRC_BLOCKED = (
    '/home/u/p/.envrc',
    '/home/u/p/sub/dir/.envrc',
    '/home/u/p/.ENVRC',        # re.IGNORECASE
    '.envrc',
    '.envrc.local',
    '/home/u/p/sub/.envrc.local',
    '/home/u/p/.envrc.bak',
    '/home/u/p/.ENVRC.LOCAL',
    # The template exemption is for dotenv templates only; `.envrc.example` is shell that
    # would run once copied into place, so it stays covered (conservative; flip with care).
    '/home/u/p/.envrc.example',
)
# The committed templates are exempt (matching is IGNORECASE, so case variants too). A file
# named `.env.example` inside a DIRECTORY named `.env` (a common virtualenv name) is judged
# by its final component -- the pattern needs `$` right after the `.env` token it consumes.
TEMPLATES_ALLOWED = (
    '.env.example',
    '.env.sample',
    '.env.template',
    '/home/u/p/.env.example',
    '/home/u/p/.env.sample',
    '/home/u/p/.env.template',
    '/home/u/p/config/.env.example',
    '/home/u/p/.ENV.EXAMPLE',
    '/home/u/p/.env.Sample',
    '/home/u/p/.env/.env.example',
)
# `.envx`, `.envrcx` and `.envrc-old` are NOT special-cased: after `.env` the regex accepts
# only end-of-path, `rc` (then end-of-path or a `.` suffix) or a `.` suffix, so a name that
# merely starts with `.env`/`.envrc` but continues with any other character is a different
# file. The pre-existing policy never covered `.envx` / `.env-old` either; `.envrc-old` and
# `.envrcx` are deliberately consistent with them. Pinned so a future widening is a decision.
ALLOWED = (
    '/home/u/p/environment.py',
    '/home/u/p/README.md',
    '/home/u/p/.envx',
    '/home/u/p/.env-old',
    '/home/u/p/.envrcx',
    '/home/u/p/.envrc-old',
) + TEMPLATES_ALLOWED


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

    def test_envrc_is_blocked_without_a_security_record(self):
        # `.envrc` (direnv) executes arbitrary shell on `cd`; Ed decided 2026-10-06 that it is
        # covered. (This test used to PIN the opposite behaviour.)
        for path in ENVRC_BLOCKED:
            with self.subTest(path=path):
                code, msg = gg._policy_evaluate(path, SESS)
                self.assertEqual(code, 2, msg)
                self.assertIn(f'Policy "{POLICY_ID}"', msg)

    def test_envrc_is_unblocked_by_a_security_record(self):
        self.record('security', 'DONE')
        for path in ENVRC_BLOCKED:
            with self.subTest(path=path):
                self.assertEqual(gg._policy_evaluate(path, SESS), (0, None))

    def test_template_exemption_needs_no_security_record_and_edits_route_through(self):
        for tool in ('Write', 'Edit'):
            for path in ('/home/u/p/.env.example', '/home/u/p/.env.sample', '/home/u/p/.env.template'):
                with self.subTest(tool=tool, path=path):
                    code, msg = gg.evaluate(tool, {'file_path': path}, SESS)
                    self.assertEqual(code, 0, msg)
                    self.assertNotIn(f'Policy "{POLICY_ID}"', msg or '')

    def test_template_name_with_trailing_newline_is_still_refused(self):
        # `$` matches before a trailing newline, so the regex alone would exempt
        # `.env.example\n`; the guard's control-char gate runs first and fails it closed.
        for path in ('/home/u/p/.env.example\n', '/home/u/p/.env.sample\n', '/home/u/p/.env.template\x00'):
            with self.subTest(path=path):
                code, msg = gg._policy_evaluate(path, SESS)
                self.assertEqual(code, 2, msg)

    def test_symlink_named_like_a_template_to_a_real_env_file_is_blocked(self):
        # The guard matches the raw path AND its realpath; a template-named symlink cannot
        # launder a write to a real `.env` (or `.envrc`).
        proj = os.path.join(self.home, 'proj')
        os.makedirs(proj)
        for target in ('.env', '.envrc', '.env.production'):
            with self.subTest(target=target):
                open(os.path.join(proj, target), 'w').close()
                link = os.path.join(proj, '.env.example')
                if os.path.lexists(link):
                    os.unlink(link)
                os.symlink(os.path.join(proj, target), link)
                code, msg = gg._policy_evaluate(link, SESS)
                self.assertEqual(code, 2, msg)
                self.assertIn(f'Policy "{POLICY_ID}"', msg)

    def test_pathological_long_paths_evaluate_quickly(self):
        # No nested quantifiers: a 4000-char path stays far below the 5 s hook timeout.
        # Both shapes: all `.env` repeats (matches at once) and `.envX` repeats (the
        # worst case -- every `.env` token is tried and fails).
        for label, path in (
            ('dot-env repeats', '/' + '.env' * 999),
            ('near-miss repeats', '/' + '.envX' * 799),
            ('template repeats', '/' + '.env.example' * 307),
            ('envrc repeats', '/' + '.envrc.' * 570),
            ('envrc near-miss repeats', '/' + '.envrcX' * 570),
        ):
            with self.subTest(label=label):
                self.assertLessEqual(len(path), 4000 + 1)
                start = time.monotonic()
                code, _msg = gg._policy_evaluate(path, SESS)
                elapsed = time.monotonic() - start
                self.assertIn(code, (0, 2))
                self.assertLess(elapsed, 1.0, f'{label}: {elapsed:.3f}s')

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
