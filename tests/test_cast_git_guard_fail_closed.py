#!/usr/bin/env python3
"""Fail-closed tests for the Write/Edit policy gate (Ed decision, 2026-10-05).

`scripts/cast-git-guard.py::evaluate()` used to wrap everything in
`try: ... except Exception: return 0, ''`, so ANY unexpected exception in the Write/Edit
branch (`_policy_evaluate`, `_ttl_sweep_agent_status`) ALLOWED the write. Now:

  * Write/Edit  -> an internal error BLOCKS with a `**[CAST-POLICY-BLOCK]**` reason that names
                   the exception CLASS only (never str(exc) / the path: attacker-controlled
                   text). `CAST_POLICY_OVERRIDE=1` allows, audited as `policy-internal-error`.
  * Bash        -> an internal error still fails OPEN (a guard bug must not block every Bash
                   call; the irreversible git ops are also guarded in main()).
  * other tools -> (0, '').
  * `scripts/cast-pretool-dispatch.py` -> an exception escaping `git_guard.evaluate()` for a
                   Write/Edit blocks too (same hatch); module-LOAD failure is NOT covered here.

Round 2 (security review) covers handlers that swallowed errors BEFORE that layer: a lone
surrogate in file_path (realpath raised, was swallowed, symlink bypass), an unparseable
Write/Edit payload in the dispatcher, and the unbounded TTL sweep.

HOME is redirected to a temp dir for every test (never the real ~/.claude). Hyphenated
filenames are loaded via importlib, same pattern as tests/test_cast_git_guard_status_gate.py.
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent


def _load_script(mod_name, filename):
    spec = importlib.util.spec_from_file_location(mod_name, str(_REPO / 'scripts' / filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gg = _load_script('cast_git_guard_fail_closed', 'cast-git-guard.py')
dispatch = _load_script('cast_pretool_dispatch_fail_closed', 'cast-pretool-dispatch.py')

SENTINEL = 'SENTINEL-attacker-controlled-text-7f3a'
SESS = 'sess-1'
WRITE_PATH = '/home/u/x.txt'


class _IsolatedEnv(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-failclosed-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SESSION_ID', 'CLAUDE_SUBPROCESS', 'CLAUDE_DIR'):
            os.environ.pop(k, None)


class TestEvaluateWriteEditFailsClosed(_IsolatedEnv):

    def _assert_blocked_without_leak(self, code, msg, path=WRITE_PATH):
        self.assertEqual(code, 2)
        self.assertIn('[CAST-POLICY-BLOCK]', msg)
        self.assertIn('RuntimeError', msg)
        self.assertIn('CAST_POLICY_OVERRIDE=1', msg)
        self.assertNotIn(SENTINEL, msg)   # exception MESSAGE must never reach the reason
        self.assertNotIn(path, msg)       # nor the (attacker-steerable) path

    def test_write_policy_exception_blocks(self):
        with mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)):
            code, msg = gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS)
        self._assert_blocked_without_leak(code, msg)

    def test_edit_policy_exception_blocks(self):
        with mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)):
            code, msg = gg.evaluate('Edit', {'file_path': WRITE_PATH}, SESS)
        self._assert_blocked_without_leak(code, msg)
        self.assertIn('Edit', msg)

    def test_path_key_fallback_also_fails_closed(self):
        with mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)):
            code, msg = gg.evaluate('Write', {'path': WRITE_PATH}, SESS)
        self._assert_blocked_without_leak(code, msg)

    def test_override_allows_and_audits_internal_error(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}), \
                mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)), \
                mock.patch.object(gg, '_audit_policy_override') as audit:
            code, msg = gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS)
        self.assertEqual((code, msg), (0, ''))
        audit.assert_called_once_with('policy-internal-error', WRITE_PATH, SESS)

    def test_override_audit_session_falls_back_to_env(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1', 'CLAUDE_SESSION_ID': 'env-sess'}), \
                mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)), \
                mock.patch.object(gg, '_audit_policy_override') as audit:
            code, _ = gg.evaluate('Write', {'file_path': WRITE_PATH}, '')
        self.assertEqual(code, 0)
        audit.assert_called_once_with('policy-internal-error', WRITE_PATH, 'env-sess')

    def test_override_with_raising_audit_still_allows(self):
        """The hatch path itself must not be able to raise out of evaluate()."""
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}), \
                mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)), \
                mock.patch.object(gg, '_audit_policy_override', side_effect=OSError(SENTINEL)):
            code, msg = gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS)
        self.assertEqual((code, msg), (0, ''))

    def test_non_one_override_value_does_not_allow(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': 'true'}), \
                mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)):
            code, msg = gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS)
        self._assert_blocked_without_leak(code, msg)

    def test_raising_ttl_sweep_does_not_decide_the_verdict(self):
        with mock.patch.object(gg, '_ttl_sweep_agent_status', side_effect=RuntimeError(SENTINEL)):
            with mock.patch.object(gg, '_policy_evaluate', return_value=(0, None)):
                self.assertEqual(gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS), (0, ''))
            with mock.patch.object(gg, '_policy_evaluate', return_value=(2, 'policy says no')):
                self.assertEqual(gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS),
                                 (2, 'policy says no'))

    def test_normal_policy_verdicts_unchanged(self):
        with mock.patch.object(gg, '_policy_evaluate', return_value=(0, None)):
            self.assertEqual(gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS), (0, ''))
        with mock.patch.object(gg, '_policy_evaluate', return_value=(2, 'blocked: reason')):
            self.assertEqual(gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS),
                             (2, 'blocked: reason'))

    def test_non_dict_tool_input_write_does_not_raise(self):
        """Non-dict tool_input is coerced to {} -> missing path -> existing fail-closed block."""
        code, msg = gg.evaluate('Write', 'not-a-dict', SESS)
        self.assertEqual(code, 2)
        self.assertIn('[CAST-POLICY-BLOCK]', msg)


class TestEvaluateOtherToolsPolicy(_IsolatedEnv):

    def test_bash_internal_error_stays_fail_open(self):
        with mock.patch.object(gg, '_git_evaluate', side_effect=RuntimeError(SENTINEL)):
            self.assertEqual(gg.evaluate('Bash', {'command': 'echo hi'}, SESS), (0, ''))

    def test_bash_block_still_blocks(self):
        with mock.patch.object(gg, '_git_evaluate', return_value=(2, 'git op blocked')):
            self.assertEqual(gg.evaluate('Bash', {'command': 'x'}, SESS), (2, 'git op blocked'))

    def test_bash_does_not_consult_write_edit_policy(self):
        with mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)) as pe, \
                mock.patch.object(gg, '_git_evaluate', return_value=(0, None)):
            self.assertEqual(gg.evaluate('Bash', {'command': 'echo hi'}, SESS), (0, ''))
        pe.assert_not_called()

    def test_unknown_tool_allows(self):
        with mock.patch.object(gg, '_policy_evaluate', side_effect=RuntimeError(SENTINEL)), \
                mock.patch.object(gg, '_git_evaluate', side_effect=RuntimeError(SENTINEL)):
            self.assertEqual(gg.evaluate('Read', {'file_path': WRITE_PATH}, SESS), (0, ''))
            self.assertEqual(gg.evaluate('', {}, SESS), (0, ''))


class TestDispatcherWriteEditFailsClosed(_IsolatedEnv):
    """main() drives a Write payload through a stubbed `_load` whose guard.evaluate raises."""

    def setUp(self):
        super().setUp()
        self.guard = types.SimpleNamespace(
            evaluate=mock.Mock(side_effect=RuntimeError(SENTINEL)),
            _audit_policy_override=mock.Mock(),
        )
        # Only the git guard is stubbed in; every other optional module is "failed to load".
        load = mock.patch.object(
            dispatch, '_load',
            side_effect=lambda name, fn: self.guard if name == 'cast_git_guard' else None)
        load.start()
        self.addCleanup(load.stop)

    def _run(self, payload):
        raw = json.dumps(payload).encode('utf-8')
        stdin = io.TextIOWrapper(io.BytesIO(raw), encoding='utf-8')
        err = io.StringIO()
        with mock.patch.object(sys, 'stdin', stdin), contextlib.redirect_stderr(err), \
                contextlib.redirect_stdout(io.StringIO()):
            rc = dispatch.main()
        return rc, err.getvalue()

    def _write_payload(self, tool='Write'):
        return {'tool_name': tool, 'tool_input': {'file_path': WRITE_PATH}, 'session_id': SESS}

    def _hook_errors_log(self):
        p = os.path.join(self.home, '.claude', 'logs', 'hook-errors.log')
        return Path(p).read_text() if os.path.isfile(p) else ''

    def test_write_blocks_when_evaluate_raises(self):
        rc, err = self._run(self._write_payload('Write'))
        self.assertEqual(rc, 2)
        self.assertIn('[CAST-POLICY-BLOCK]', err)
        self.assertIn('RuntimeError', err)
        self.assertNotIn(SENTINEL, err)
        self.assertNotIn(WRITE_PATH, err)
        self.assertIn('CAST_POLICY_OVERRIDE=1', err)
        self.guard.evaluate.assert_called_once_with('Write', {'file_path': WRITE_PATH}, SESS)

    def test_edit_blocks_when_evaluate_raises(self):
        rc, err = self._run(self._write_payload('Edit'))
        self.assertEqual(rc, 2)
        self.assertIn('[CAST-POLICY-BLOCK]', err)

    def test_exception_class_logged_but_not_message(self):
        self._run(self._write_payload())
        log = self._hook_errors_log()
        self.assertIn('RuntimeError', log)
        self.assertNotIn(SENTINEL, log)

    def test_override_allows_and_audits(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            rc, err = self._run(self._write_payload())
        self.assertEqual(rc, 0)
        self.assertEqual(err, '')
        self.guard._audit_policy_override.assert_called_once_with(
            'policy-internal-error', WRITE_PATH, SESS)

    def test_override_with_raising_audit_still_allows(self):
        self.guard._audit_policy_override.side_effect = OSError(SENTINEL)
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            rc, err = self._run(self._write_payload())
        self.assertEqual(rc, 0)
        self.assertEqual(err, '')

    def test_policy_block_verdict_still_blocks(self):
        self.guard.evaluate = mock.Mock(return_value=(2, 'policy says no'))
        rc, err = self._run(self._write_payload())
        self.assertEqual(rc, 2)
        self.assertIn('policy says no', err)

    def test_bash_evaluate_exception_stays_fail_open(self):
        rc, err = self._run({'tool_name': 'Bash', 'tool_input': {'command': 'echo hi'},
                             'session_id': SESS})
        self.assertEqual(rc, 0)
        self.assertEqual(err, '')


# --------------------------------------------------------------------------------------
# Round 2 (security review): handlers that swallowed errors BEFORE the fail-closed layer.
# --------------------------------------------------------------------------------------
class _PolicyFixture(_IsolatedEnv):
    """Temp HOME with the repo's real policies.json installed, plus a temp project dir with a
    real `.githooks/` and symlinks to it (created in the temp dir only)."""

    def setUp(self):
        super().setUp()
        cfg = os.path.join(self.home, '.claude', 'config')
        os.makedirs(cfg)
        shutil.copy(str(_REPO / 'config' / 'policies.json'), os.path.join(cfg, 'policies.json'))
        self.root = os.path.realpath(tempfile.mkdtemp(prefix='cast-failclosed-proj-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.githooks = os.path.join(self.root, 'proj', '.githooks')
        os.makedirs(self.githooks)
        self.hooks_link = os.path.join(self.root, 'hooks-link')
        os.symlink(self.githooks, self.hooks_link)
        # What a harness filesystem op sees for a JSON "\ud800": a UTF-8 U+FFFD name.
        self.fffd_link = os.path.join(self.root, 'lnk�')
        os.symlink(self.githooks, self.fffd_link)
        # A FILE symlink onto a protected target (git-internals policy), named the same way.
        git_dir = os.path.join(self.root, 'proj', '.git')
        os.makedirs(git_dir)
        self.git_config = os.path.join(git_dir, 'config')
        Path(self.git_config).write_text('[core]\n')
        self.fffd_file_link = os.path.join(self.root, 'fl\ufffd')
        os.symlink(self.git_config, self.fffd_file_link)
        # Round-3 bypass: Python's fsencode turns a lone U+DC80..U+DCFF into a raw byte, so
        # realpath() looks up `lnk\x80` (absent -> no symlink followed), but the Node-based
        # Write/Edit encodes ANY lone surrogate as U+FFFD and opens the `lnk\ufffd` symlink.
        self.bypass_paths = {
            'dc80-dir-symlink': os.path.join(self.root, 'lnk\udc80', 'pre-commit'),
            'dc80-file-symlink': os.path.join(self.root, 'fl\udc80'),
        }
        # Last entry: a REVERSED pair (low then high) -- two lone surrogates, not an astral char.
        self.sample_surrogates = ['\udc80', '\udcff', '\ud800', '\udbff', '\ude00\ud83d']
        # (path, kind) for the two HIGH-1 repros: both ALLOWED before the fix.
        self.repro_paths = {
            'surrogate-in-symlink-dir-name': os.path.join(self.root, 'lnk\ud800', 'pre-commit'),
            'surrogate-after-symlinked-dir': os.path.join(self.hooks_link, 'pre-commit\ud800'),
        }

    def audit_policy_ids(self):
        p = os.path.join(self.home, '.claude', 'logs', 'audit.jsonl')
        if not os.path.isfile(p):
            return []
        return [json.loads(line)['policy_id'] for line in Path(p).read_text().splitlines() if line]


class TestLoneSurrogatePathFailsClosed(_PolicyFixture):

    def test_baseline_symlinked_githooks_without_surrogate_is_blocked(self):
        code, msg = gg.evaluate('Write', {'file_path': os.path.join(self.hooks_link, 'pre-commit')}, SESS)
        self.assertEqual(code, 2)
        self.assertIn('githooks-require-security', msg)

    def test_repro_paths_are_blocked_not_allowed(self):
        for kind, path in self.repro_paths.items():
            with self.subTest(kind):
                code, msg = gg.evaluate('Write', {'file_path': path}, SESS)
                self.assertEqual(code, 2)
                self.assertIn('[CAST-POLICY-BLOCK]', msg)
                self.assertIn('cannot be encoded', msg)
                self.assertNotIn(self.root, msg)  # the path is not echoed

    def test_edit_repro_paths_blocked(self):
        code, msg = gg.evaluate('Edit', {'file_path': self.repro_paths['surrogate-after-symlinked-dir']}, SESS)
        self.assertEqual(code, 2)
        self.assertIn('cannot be encoded', msg)

    def test_override_allows_and_audits_path_not_encodable(self):
        for kind, path in self.repro_paths.items():
            with self.subTest(kind):
                with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
                    self.assertEqual(gg.evaluate('Write', {'file_path': path}, SESS), (0, ''))
        self.assertEqual(self.audit_policy_ids(), ['policy-path-not-encodable'] * 2)

    def test_fixture_discriminates_python_resolution_from_node_resolution(self):
        """Proves the bypass fixture is not a proxy: Python's realpath MISSES the symlink for the
        U+DC80 spelling (it looks up byte 0x80), while the U+FFFD spelling Node opens resolves
        into the protected target. If this ever stops holding, the tests below prove nothing."""
        for kind, protected in (('dc80-dir-symlink', '.githooks'), ('dc80-file-symlink', '.git')):
            with self.subTest(kind):
                path = self.bypass_paths[kind]
                python_view = os.path.realpath(os.path.abspath(path))
                node_view = os.path.realpath(path.replace('\udc80', '\ufffd'))
                self.assertNotIn(os.sep + protected, python_view)
                self.assertIn(os.sep + protected, node_view)

    def test_dc80_surrogate_in_symlink_name_is_refused(self):
        """The round-3 bypass: both ALLOWED before the fix (evaluate returned 0)."""
        for kind, path in self.bypass_paths.items():
            for tool in ('Write', 'Edit'):
                with self.subTest(f'{tool} {kind}'):
                    code, msg = gg.evaluate(tool, {'file_path': path}, SESS)
                    self.assertEqual(code, 2)
                    self.assertIn('cannot be encoded', msg)
                    self.assertNotIn(self.root, msg)

    def test_every_lone_surrogate_in_a_symlink_name_is_refused(self):
        for sur in self.sample_surrogates:
            with self.subTest(repr(sur)):
                path = os.path.join(self.root, 'lnk' + sur, 'pre-commit')
                code, msg = gg.evaluate('Write', {'file_path': path}, SESS)
                self.assertEqual(code, 2)
                self.assertIn('cannot be encoded', msg)

    def test_dc80_bypass_with_override_allows_and_audits(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            for path in self.bypass_paths.values():
                self.assertEqual(gg.evaluate('Write', {'file_path': path}, SESS), (0, ''))
        self.assertEqual(self.audit_policy_ids(), ['policy-path-not-encodable'] * 2)

    # -- positive controls: valid UTF-8 is NOT refused and is policy-checked normally ----------
    def test_astral_code_point_in_benign_path_is_allowed(self):
        path = os.path.join(self.root, 'dir-\U0001F600', 'x.txt')
        self.assertEqual(gg.evaluate('Write', {'file_path': path}, SESS), (0, ''))

    def test_literal_fffd_in_benign_path_is_allowed(self):
        path = os.path.join(self.root, 'benign\ufffd', 'x.txt')
        self.assertEqual(gg.evaluate('Write', {'file_path': path}, SESS), (0, ''))

    def test_literal_fffd_through_symlink_hits_the_resolved_policy(self):
        """No surrogate at all: `lnk\ufffd` is a normal symlink and the resolved githooks / git
        policies must still block (the gate is not just refusing odd characters)."""
        code, msg = gg.evaluate('Write', {'file_path': os.path.join(self.fffd_link, 'pre-commit')}, SESS)
        self.assertEqual(code, 2)
        self.assertIn('githooks-require-security', msg)
        self.assertNotIn('cannot be encoded', msg)
        code, msg = gg.evaluate('Write', {'file_path': self.fffd_file_link}, SESS)
        self.assertEqual(code, 2)
        self.assertIn('git-internals-require-security', msg)
        self.assertNotIn('cannot be encoded', msg)

    def test_realpath_failure_propagates_to_fail_closed_handler(self):
        """(b) a realpath failure must not degrade to raw-path-only matching."""
        with mock.patch.object(gg.os.path, 'realpath', side_effect=OSError(SENTINEL)):
            code, msg = gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS)
        self.assertEqual(code, 2)
        self.assertIn('[CAST-POLICY-BLOCK]', msg)
        self.assertIn('OSError', msg)
        self.assertNotIn(SENTINEL, msg)

    def test_realpath_failure_with_override_allows_and_audits_internal_error(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}), \
                mock.patch.object(gg.os.path, 'realpath', side_effect=OSError(SENTINEL)):
            self.assertEqual(gg.evaluate('Write', {'file_path': WRITE_PATH}, SESS), (0, ''))
        self.assertEqual(self.audit_policy_ids(), ['policy-internal-error'])

    def test_path_is_strict_utf8_helper(self):
        for ok in ('/home/u/x.txt', '/home/u/\U0001F600', '/home/u/\ufffd', '/home/u/\u00e9'):
            self.assertTrue(gg._path_is_strict_utf8(ok), repr(ok))
        # Every lone surrogate is refused -- including U+DC80..DCFF, which os.fsencode ACCEPTS
        # (surrogateescape) and which is exactly the bug's premise.
        for bad in ('/home/u/\udc80', '/home/u/\udcff', '/home/u/\ud800', '/home/u/\udfff',
                    '/home/u/\ude00\ud83d'):
            self.assertFalse(gg._path_is_strict_utf8(bad), repr(bad))
        self.assertEqual(os.fsencode('/home/u/\udc80')[-1:], b'\x80')  # os.fsencode would pass it


class _RealGuardDispatch(_PolicyFixture):
    """main() against the REAL guard module (no stubbed _load)."""

    def setUp(self):
        super().setUp()
        dispatch._MODULE_CACHE.pop('cast_git_guard', None)
        self.addCleanup(dispatch._MODULE_CACHE.pop, 'cast_git_guard', None)

    def run_raw(self, raw):
        stdin = io.TextIOWrapper(io.BytesIO(raw.encode('utf-8')), encoding='utf-8')
        err, out = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, 'stdin', stdin), contextlib.redirect_stderr(err), \
                contextlib.redirect_stdout(out):
            rc = dispatch.main()
        return rc, err.getvalue(), out.getvalue()

    def run_payload(self, payload):
        return self.run_raw(json.dumps(payload))


class TestDispatcherLoneSurrogate(_RealGuardDispatch):

    def _payload(self, path, tool='Write'):
        return {'tool_name': tool, 'tool_input': {'file_path': path}, 'session_id': SESS}

    def test_repro_paths_blocked_via_main(self):
        for kind, path in self.repro_paths.items():
            with self.subTest(kind):
                self.assertIn('\\ud8', json.dumps(self._payload(path)))  # a real JSON surrogate escape
                rc, err, _ = self.run_payload(self._payload(path))
                self.assertEqual(rc, 2)
                self.assertIn('[CAST-POLICY-BLOCK]', err)

    def test_repro_paths_allowed_with_override_and_audited(self):
        for kind, path in self.repro_paths.items():
            with self.subTest(kind), mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
                rc, err, _ = self.run_payload(self._payload(path))
                self.assertEqual((rc, err), (0, ''))
        self.assertEqual(self.audit_policy_ids(), ['policy-path-not-encodable'] * 2)

    def test_dc80_bypass_paths_blocked_via_main(self):
        for kind, path in self.bypass_paths.items():
            with self.subTest(kind):
                rc, err, _ = self.run_payload(self._payload(path))
                self.assertEqual(rc, 2)
                self.assertIn('[CAST-POLICY-BLOCK]', err)
                self.assertIn('cannot be encoded', err)

    def test_every_lone_surrogate_in_a_symlink_name_blocked_via_main(self):
        for sur in self.sample_surrogates:
            with self.subTest(repr(sur)):
                rc, err, _ = self.run_payload(
                    self._payload(os.path.join(self.root, 'lnk' + sur, 'pre-commit')))
                self.assertEqual(rc, 2)
                self.assertIn('cannot be encoded', err)

    def test_dc80_bypass_with_override_via_main_allows_and_audits(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            for path in self.bypass_paths.values():
                self.assertEqual(self.run_payload(self._payload(path))[:2], (0, ''))
        self.assertEqual(self.audit_policy_ids(), ['policy-path-not-encodable'] * 2)

    def test_valid_utf8_controls_via_main(self):
        # json.dumps escapes U+1F600 as the pair "\ud83d\ude00"; json.loads recombines it into ONE
        # astral code point, so a legitimate JSON-escaped emoji path is not a lone surrogate.
        astral = self._payload(os.path.join(self.root, 'dir-\U0001F600', 'x.txt'))
        self.assertIn('\\ud83d\\ude00', json.dumps(astral))
        self.assertEqual(self.run_payload(astral)[:2], (0, ''))
        self.assertEqual(self.run_payload(
            self._payload(os.path.join(self.root, 'benign\ufffd', 'x.txt')))[:2], (0, ''))
        rc, err, _ = self.run_payload(self._payload(os.path.join(self.fffd_link, 'pre-commit')))
        self.assertEqual(rc, 2)
        self.assertIn('githooks-require-security', err)


class TestDispatcherUnparseablePayload(_RealGuardDispatch):
    """MEDIUM-2: a payload made unparseable (here: 200000-deep nesting in an extra tool_input
    key -> a REAL RecursionError from json.loads on both 3.9 and 3.14; no patching) must not
    skip the Write/Edit policy gate."""
    N = 200000

    def _deep(self, tool, name_first=True):
        deep = '[' * self.N + ']' * self.N
        inp = '{"file_path":"/home/u/x","zz":' + deep + '}'
        if name_first:
            return '{"tool_name":"%s","tool_input":%s}' % (tool, inp)
        return '{"tool_input":%s,"tool_name" : "%s"}' % (inp, tool)

    def test_fixture_really_fails_to_parse(self):
        with self.assertRaises(RecursionError):
            json.loads(self._deep('Write'))

    def test_unparseable_write_blocks(self):
        rc, err, out = self.run_raw(self._deep('Write'))
        self.assertEqual(rc, 2)
        self.assertIn('[CAST-POLICY-BLOCK]', err)
        self.assertIn('RecursionError', err)
        self.assertIn('Write', err)
        self.assertNotIn('/home/u/x', err)   # no raw payload text
        self.assertNotIn('[[[[', err)
        self.assertEqual(out, '')            # block is stderr + exit 2 only; no stdout object

    def test_unparseable_edit_blocks_even_when_tool_name_comes_last(self):
        rc, err, _ = self.run_raw(self._deep('Edit', name_first=False))
        self.assertEqual(rc, 2)
        self.assertIn('Edit', err)

    def test_unparseable_write_with_override_allows_and_audits(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            rc, err, out = self.run_raw(self._deep('Write'))
        self.assertEqual((rc, err, out), (0, '', ''))
        self.assertEqual(self.audit_policy_ids(), ['policy-internal-error'])

    def test_unparseable_write_skipped_for_subprocess_like_the_parsed_path(self):
        with mock.patch.dict(os.environ, {'CLAUDE_SUBPROCESS': '1'}):
            rc, err, _ = self.run_raw(self._deep('Write'))
        self.assertEqual((rc, err), (0, ''))

    def test_unparseable_non_write_keeps_old_behaviour(self):
        for tool in ('Read', 'Bash', 'NotAWriteEdit'):
            with self.subTest(tool):
                rc, err, out = self.run_raw(self._deep(tool))
                self.assertEqual((rc, err, out), (0, '', ''))

    def test_unparseable_neon_still_gets_the_ask_object(self):
        rc, err, out = self.run_raw(self._deep('mcp__neon__delete_project'))
        self.assertEqual(rc, 0)
        self.assertEqual(err, '')
        obj, end = json.JSONDecoder().raw_decode(out.strip())
        self.assertEqual(end, len(out.strip()))   # exactly one stdout object
        self.assertEqual(obj['hookSpecificOutput']['permissionDecision'], 'ask')

    def test_malformed_but_not_deep_write_blocks_too(self):
        rc, err, _ = self.run_raw('{"tool_name":"Write","tool_input":{"file_path":"/home/u/x"')  # truncated
        self.assertEqual(rc, 2)
        self.assertIn('JSONDecodeError', err)

    def test_garbage_without_tool_name_is_allowed_as_before(self):
        self.assertEqual(self.run_raw('not json at all')[0], 0)


class TestTtlSweepIsBounded(_IsolatedEnv):

    def _make_stale(self, n):
        d = os.path.join(self.home, '.claude', 'agent-status')
        os.makedirs(d, exist_ok=True)
        old = time.time() - 3 * 3600
        for i in range(n):
            f = os.path.join(d, f'rec-{i}.json')
            Path(f).write_text('{}')
            os.utime(f, (old, old))
        return d

    def test_sweep_stops_after_max_entries(self):
        d = self._make_stale(6)
        with mock.patch.object(gg, '_STATUS_MAX_FILES', 3):
            gg._ttl_sweep_agent_status()
        self.assertEqual(len(os.listdir(d)), 3)   # exactly the cap was examined/deleted
        gg._ttl_sweep_agent_status()              # the next sweep continues the work
        self.assertEqual(len(os.listdir(d)), 0)

    def test_sweep_under_the_cap_deletes_every_stale_record(self):
        d = self._make_stale(6)
        gg._ttl_sweep_agent_status()
        self.assertEqual(os.listdir(d), [])


if __name__ == '__main__':
    unittest.main()
