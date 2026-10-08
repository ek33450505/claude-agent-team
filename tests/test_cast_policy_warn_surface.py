#!/usr/bin/env python3
"""Unit W: `warn`-severity Write/Edit policies reach the model as PreToolUse additionalContext.

A matching warn policy NEVER blocks (exit stays 0) but is surfaced as exactly ONE
hookSpecificOutput JSON object on stdout (Claude Code blocks the call when two objects are
concatenated). A block policy that also matches still wins (exit 2).

Every subprocess run uses a throw-away HOME (tempfile.mkdtemp) holding a copy of the repo's
config/policies.json -- the real ~/.claude is never touched.
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent
_SCRIPTS = _REPO / 'scripts'
_DISPATCH = _SCRIPTS / 'cast-pretool-dispatch.py'
_GUARD = _SCRIPTS / 'cast-git-guard.py'
_POLICIES = _REPO / 'config' / 'policies.json'

SESS = 'sess-warn-surface-1'


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dispatch = _load('cast_pretool_dispatch_warn_surface', _DISPATCH)


class _TempHome(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-warnsurf-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        os.makedirs(os.path.join(self.home, '.claude', 'agent-status'))
        cfg = os.path.join(self.home, '.claude', 'config')
        os.makedirs(cfg)
        shutil.copy(str(_POLICIES), os.path.join(cfg, 'policies.json'))
        self.proj = os.path.join(self.home, 'proj')
        os.makedirs(self.proj)

    def _env(self):
        env = dict(os.environ)
        env['HOME'] = self.home
        env['CAST_DB_PATH'] = os.path.join(self.home, 'nonexistent-cast.db')
        for k in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SUBPROCESS', 'CLAUDE_SESSION_ID', 'CLAUDE_DIR'):
            env.pop(k, None)
        return env

    def _spawn(self, script, payload):
        return subprocess.run(
            [sys.executable, str(script)],
            input=json.dumps(payload).encode('utf-8'),
            capture_output=True, env=self._env(), timeout=60)

    def _write_payload(self, rel):
        return {'tool_name': 'Write', 'session_id': SESS,
                'tool_input': {'file_path': os.path.join(self.proj, rel), 'content': 'x'}}


class TestDispatcherSurfacesWarn(_TempHome):
    def test_warn_policy_emits_one_additional_context_object(self):
        proc = self._spawn(_DISPATCH, self._write_payload('credentials.json'))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = proc.stdout.decode('utf-8')
        obj = json.loads(out)  # exactly one parseable object (two concatenated would raise)
        hso = obj['hookSpecificOutput']
        self.assertEqual(hso['hookEventName'], 'PreToolUse')
        self.assertIn('CAST-POLICY-WARN', hso['additionalContext'])
        self.assertIn('credentials-files-warn', hso['additionalContext'])
        self.assertNotIn('permissionDecision', hso)
        self.assertNotIn('CAST-POLICY-BLOCK', proc.stderr.decode('utf-8'))

    def test_block_policy_still_wins_over_warn(self):
        # `<proj>/auth/.env` matches env-files-require-security (block) AND
        # auth-dirs-outside-src-warn (warn).
        proc = self._spawn(_DISPATCH, self._write_payload('auth/.env'))
        self.assertEqual(proc.returncode, 2, proc.stdout)
        self.assertIn('CAST-POLICY-BLOCK', proc.stderr.decode('utf-8'))
        self.assertEqual(proc.stdout, b'')

    def test_non_matching_path_is_silent(self):
        proc = self._spawn(_DISPATCH, self._write_payload('README.md'))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b'')


class TestStandaloneGuardSurfacesWarn(_TempHome):
    def test_main_prints_single_json_on_warn(self):
        # The standalone guard is not loaded from ~/.claude/scripts, so it reads the temp
        # HOME's installed policies.json exactly as the dispatcher does.
        proc = self._spawn(_GUARD, self._write_payload('secrets.yaml'))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        obj = json.loads(proc.stdout.decode('utf-8'))
        ctx = obj['hookSpecificOutput']['additionalContext']
        self.assertEqual(obj['hookSpecificOutput']['hookEventName'], 'PreToolUse')
        self.assertIn('CAST-POLICY-WARN', ctx)
        self.assertIn('secrets-files-warn', ctx)

    def test_main_silent_when_no_match(self):
        proc = self._spawn(_GUARD, self._write_payload('README.md'))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b'')

    def test_main_block_still_exits_2(self):
        proc = self._spawn(_GUARD, self._write_payload('auth/.env'))
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, b'')


class TestWarnTextBounds(_TempHome):
    def test_warn_lines_capped_with_more_suffix(self):
        gg = _load('cast_git_guard_warn_surface', _GUARD)
        pols = {'policies': [
            {'id': f'w{i}', 'path_pattern': r'target\.txt$', 'severity': 'warn',
             'requires_agent': 'security', 'description': f'desc {i}'}
            for i in range(6)
        ] + [
            # the engine fails closed on a config with no block policy
            {'id': 'b0', 'path_pattern': r'never-matches-xyz$', 'severity': 'block',
             'requires_agent': 'security', 'description': 'unused'},
        ]}
        with open(os.path.join(self.home, '.claude', 'config', 'policies.json'), 'w') as f:
            json.dump(pols, f)
        with mock.patch.dict(os.environ, {'HOME': self.home}):
            os.environ.pop('CAST_POLICY_OVERRIDE', None)
            code, msg = gg._policy_evaluate(os.path.join(self.proj, 'target.txt'), SESS)
        self.assertEqual(code, 0)
        self.assertEqual(msg.count('[CAST-POLICY-WARN]'), 4)
        self.assertIn('w0', msg)
        self.assertNotIn('"w4"', msg)
        self.assertTrue(msg.rstrip().endswith('(+2 more)'), msg)


class TestWarnTextHardening(_TempHome):
    """Warn text is model-visible: the echoed path is escaped and the description capped."""

    def setUp(self):
        super().setUp()
        self.gg = _load('cast_git_guard_warn_hardening', _GUARD)
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SESSION_ID', 'CLAUDE_DIR'):
            os.environ.pop(k, None)

    def _write_policies(self, warn_desc='d'):
        pols = {'policies': [
            {'id': 'w-cred', 'path_pattern': r'credentials', 'severity': 'warn',
             'requires_agent': 'security', 'description': warn_desc},
            {'id': 'b-env', 'path_pattern': r'\.env$', 'severity': 'block',
             'requires_agent': 'security', 'description': 'block'},
        ]}
        with open(os.path.join(self.home, '.claude', 'config', 'policies.json'), 'w') as f:
            json.dump(pols, f)

    def test_hostile_path_chars_are_escaped(self):
        self._write_policies()
        raw = '\u202e\u2028\u009b`'
        code, msg = self.gg._policy_evaluate(
            os.path.join(self.proj, 'credentials' + raw + '.json'), SESS)
        self.assertEqual(code, 0, msg)
        for ch in raw[:-1]:  # the backtick is covered by the count below (template has its own)
            self.assertNotIn(ch, msg)
        for esc in ('\\u202e', '\\u2028', '\\u009b', '\\u0060'):
            self.assertIn(esc, msg)
        # only the template's own two code spans (path, agent) remain: 4 backticks, not 5
        self.assertEqual(msg.count('`'), 4)

    def test_astral_tag_chars_use_long_escape(self):
        self._write_policies()
        code, msg = self.gg._policy_evaluate(
            os.path.join(self.proj, 'credentials\U000e0041.json'), SESS)
        self.assertEqual(code, 0, msg)
        self.assertNotIn('\U000e0041', msg)
        self.assertIn('\\U000e0041', msg)

    def test_description_is_capped(self):
        self._write_policies(warn_desc='x' * 1000)
        code, msg = self.gg._policy_evaluate(os.path.join(self.proj, 'credentials.json'), SESS)
        self.assertEqual(code, 0, msg)
        self.assertNotIn('x' * 301, msg)
        self.assertIn('x' * 300 + '\u2026', msg)

    def test_short_description_not_truncated(self):
        self._write_policies(warn_desc='y' * 300)
        _, msg = self.gg._policy_evaluate(os.path.join(self.proj, 'credentials.json'), SESS)
        self.assertIn('y' * 300 + '. ', msg)
        self.assertNotIn('\u2026', msg)

    def test_non_int_cap_constant_fails_closed(self):
        self._write_policies()
        with mock.patch.object(self.gg, '_POLICY_WARN_MAX_LINES', 'four'):
            code, msg = self.gg.evaluate(
                'Write', {'file_path': os.path.join(self.proj, 'credentials.json')}, SESS)
        self.assertEqual(code, 2, msg)
        self.assertIn('CAST-POLICY-BLOCK', msg)

    def test_block_precedes_warn_even_with_broken_cap_constant(self):
        # Shows block precedence only: the block policy returns 2 BEFORE the warn lines (and so
        # the cap constant) are touched, so this is not a fail-closed check for the constant.
        self._write_policies()
        with mock.patch.object(self.gg, '_POLICY_WARN_MAX_LINES', 'four'):
            code, msg = self.gg.evaluate(
                'Write', {'file_path': os.path.join(self.proj, '.env')}, SESS)
        self.assertEqual(code, 2, msg)
        self.assertIn('Policy "b-env"', msg)

    def test_literal_backslash_is_doubled_so_text_cannot_fake_an_escape(self):
        self._write_policies()
        literal = '\\u202e'  # backslash, u, 2, 0, 2, e as plain text (not U+202E)
        code, msg = self.gg._policy_evaluate(
            os.path.join(self.proj, 'credentials' + literal + '.json'), SESS)
        self.assertEqual(code, 0, msg)
        self.assertIn('credentials' + '\\' + literal + '.json', msg)  # doubled backslash
        self.assertNotIn('credentials' + literal + '.json', msg)
        # injective: a real U+202E renders differently from the literal text
        _, real = self.gg._policy_evaluate(
            os.path.join(self.proj, 'credentials\u202e.json'), SESS)
        self.assertNotEqual(msg.split('flags')[1], real.split('flags')[1])

    def test_escape_helper_doubles_backslash_and_escapes_lone_surrogate(self):
        esc = self.gg._escape_for_context
        self.assertEqual(esc('a\\b'), 'a\\\\b')
        self.assertEqual(esc('\ud800'), '\\ud800')
        self.assertNotIn('\ud800', esc('x\ud800y'))

    def test_lone_surrogate_path_is_blocked_before_the_warn(self):
        # `_path_block`'s strict-UTF-8 check rejects the path before any policy runs, so a
        # lone surrogate never reaches the warn builder: code 2, not a warn.
        self._write_policies()
        code, msg = self.gg._policy_evaluate(
            os.path.join(self.proj, 'credentials\ud800.json'), SESS)
        self.assertEqual(code, 2, msg)
        self.assertNotIn('CAST-POLICY-WARN', msg)
        self.assertNotIn('\ud800', msg)


class TestEmitPretoolOutput(unittest.TestCase):
    ACTION = ('advisory', {'severity': 'info', 'reason': 'egress reason', 'recorded': True})

    @staticmethod
    def _sentinel():
        return _load('cast_egress_sentinel_warn_surface', _SCRIPTS / 'cast-egress-sentinel.py')

    def _capture(self, *args):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            dispatch._emit_pretool_output(*args)
        return buf.getvalue()

    def test_neon_ask_plus_extra_context_is_one_object(self):
        out = self._capture(None, None, 'neon reason', 'WARN TEXT')
        hso = json.loads(out)['hookSpecificOutput']
        self.assertEqual(hso['permissionDecision'], 'ask')
        self.assertEqual(hso['permissionDecisionReason'], 'neon reason')
        self.assertIn('WARN TEXT', hso['additionalContext'])

    def test_neon_ask_plus_egress_plus_extra_joined_in_one_object(self):
        sentinel = self._sentinel()
        out = self._capture(sentinel, self.ACTION, 'neon reason', 'WARN TEXT')
        hso = json.loads(out)['hookSpecificOutput']
        self.assertEqual(hso['permissionDecision'], 'ask')
        self.assertEqual(
            hso['additionalContext'],
            sentinel.advisory_context(self.ACTION[1]) + '\nWARN TEXT')

    def test_extra_context_only_is_one_object(self):
        out = self._capture(None, None, None, 'WARN TEXT')
        self.assertEqual(json.loads(out), {'hookSpecificOutput': {
            'hookEventName': 'PreToolUse', 'additionalContext': 'WARN TEXT'}})

    def test_egress_plus_extra_without_neon_is_one_object(self):
        sentinel = self._sentinel()
        out = self._capture(sentinel, self.ACTION, None, 'WARN TEXT')
        hso = json.loads(out)['hookSpecificOutput']
        self.assertNotIn('permissionDecision', hso)
        self.assertEqual(
            hso['additionalContext'],
            sentinel.advisory_context(self.ACTION[1]) + '\nWARN TEXT')

    def test_nothing_to_say_prints_nothing(self):
        self.assertEqual(self._capture(None, None, None), '')
        self.assertEqual(self._capture(None, None, None, None), '')
        self.assertEqual(self._capture(None, None, None, ''), '')

    def test_extra_none_egress_output_identical_to_emit_advisory(self):
        sentinel = self._sentinel()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            sentinel.emit_advisory(self.ACTION[1])
        self.assertTrue(buf.getvalue())
        self.assertEqual(self._capture(sentinel, self.ACTION, None), buf.getvalue())
        self.assertEqual(self._capture(sentinel, self.ACTION, None, None), buf.getvalue())

    def test_never_raises_on_hostile_inputs(self):
        # sentinel None + advisory action, non-str extra: must not raise.
        self._capture(None, self.ACTION, None, 12345)
        self._capture(None, self.ACTION, 'neon reason', object())


if __name__ == '__main__':
    unittest.main()
