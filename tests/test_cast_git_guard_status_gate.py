#!/usr/bin/env python3
"""Tests for the requires_agent completion gate in scripts/cast-git-guard.py
(`_agent_completed_this_session`, `_read_status_record`, `_ttl_sweep_agent_status`).

S3d unit 2 security-review follow-ups (2026-10-05):
  H1  a reader error (RecursionError from a deeply nested junk record under
      CPython 3.9) must never escape: it would reach evaluate()'s blanket
      `except Exception: return 0, ''` and fail EVERY policy block open.
  L1  the payload session_id must fullmatch the writer's [A-Za-z0-9-]{1,64}.
  L2  equal-mtime ties are conservative (a non-passing record wins).
  L3  the TTL sweep uses the fixed ~/.claude/agent-status (not env CLAUDE_DIR)
      and never follows a symlinked directory or entry.
Delta review: control-character paths fail closed before any regex (cubic backtracking on an
embedded newline), and a non-str Write/Edit file_path fails closed instead of open.

Hyphenated filename cannot be imported normally -- load via importlib, same
pattern as tests/test_cast_git_guard_hatch.py.
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

_spec = importlib.util.spec_from_file_location('cast_git_guard_status_gate', str(_SCRIPT_PATH))
gg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gg)

_REAL_LOADS = json.loads
SESS = 'sess-1'


def _bound(status='DONE', sess=SESS, agent_type='devops'):
    return {'agent': agent_type, 'status': status, 'session_id': sess, 'agent_type': agent_type}


class _Base(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-gate-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        self.status_dir = os.path.join(self.home, '.claude', 'agent-status')
        os.makedirs(self.status_dir)
        cfg = os.path.join(self.home, '.claude', 'config')
        os.makedirs(cfg)
        shutil.copy(str(_REPO / 'config' / 'policies.json'), os.path.join(cfg, 'policies.json'))
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_POLICY_OVERRIDE', 'CLAUDE_SESSION_ID', 'CLAUDE_DIR'):
            os.environ.pop(k, None)

    def write(self, name, content, age_secs=0, d=None):
        path = os.path.join(d or self.status_dir, name)
        with open(path, 'w') as f:
            f.write(content if isinstance(content, str) else json.dumps(content))
        if age_secs:
            t = time.time() - age_secs
            os.utime(path, (t, t))
        return path

    def gate(self, session_id=SESS, agent='devops'):
        return gg._agent_completed_this_session(agent, self.status_dir, time.time(), session_id)


class TestReaderNeverRaises(_Base):
    """H1."""

    @staticmethod
    def _recursion_on_junk(s, *a, **kw):
        if s.startswith('[[[['):
            raise RecursionError('maximum recursion depth exceeded')
        return _REAL_LOADS(s, *a, **kw)

    def test_recursion_error_on_a_junk_record_is_skipped_not_raised(self):
        self.write('junk.json', '[' * 1500 + ']' * 1500)
        with mock.patch.object(gg.json, 'loads', side_effect=self._recursion_on_junk):
            self.assertIs(self.gate(), False)

    def test_junk_record_does_not_shadow_a_valid_record(self):
        self.write('junk.json', '[' * 1500 + ']' * 1500)
        self.write('good.json', _bound('DONE'))
        with mock.patch.object(gg.json, 'loads', side_effect=self._recursion_on_junk):
            self.assertIs(self.gate(), True)

    def test_memory_error_on_a_record_is_skipped_not_raised(self):
        self.write('good.json', _bound('DONE'))
        with mock.patch.object(gg.json, 'loads', side_effect=MemoryError):
            self.assertIs(self.gate(), False)

    def test_read_status_record_returns_none_on_recursion_error(self):
        path = self.write('junk.json', '[' * 1500 + ']' * 1500)
        with mock.patch.object(gg.json, 'loads', side_effect=RecursionError):
            self.assertIsNone(gg._read_status_record(path))

    def test_junk_record_cannot_open_every_policy_block(self):
        """The failure H1 described: evaluate() fail-OPEN on a reader error."""
        self.write('junk.json', '[' * 1500 + ']' * 1500)
        with mock.patch.object(gg.json, 'loads', side_effect=self._recursion_on_junk):
            code, msg = gg.evaluate('Write', {'file_path': '.github/workflows/x.yml'}, SESS)
        self.assertEqual(code, 2, msg)
        self.assertIn('workflows-require-devops', msg)

    def test_real_deep_nesting_still_blocks_on_this_interpreter(self):
        # Whatever this CPython does with 1500 levels (RecursionError on 3.9, a parsed
        # list on 3.14), no matching record exists, so the Write must stay blocked.
        self.write('junk.json', '[' * 1500 + ']' * 1500)
        code, msg = gg.evaluate('Write', {'file_path': '.github/workflows/x.yml'}, SESS)
        self.assertEqual(code, 2, msg)

    def test_policy_config_recursion_error_fails_closed(self):
        path = os.path.join(self.home, '.claude', 'config', 'policies.json')
        with mock.patch.object(gg.json, 'loads', side_effect=RecursionError):
            status, reason = gg._read_policy_config(path)
        self.assertEqual(status, 'invalid')
        with mock.patch.object(gg.json, 'loads', side_effect=RecursionError):
            code, msg = gg.evaluate('Write', {'file_path': '.github/workflows/x.yml'}, SESS)
        self.assertEqual(code, 2, msg)
        self.assertIn('failing closed', msg)

    def test_deeply_nested_policy_config_fails_closed(self):
        self.write('policies.json', '[' * 1500 + ']' * 1500, d=os.path.join(self.home, '.claude', 'config'))
        code, msg = gg.evaluate('Write', {'file_path': '.github/workflows/x.yml'}, SESS)
        self.assertEqual(code, 2, msg)


class TestSessionIdShape(_Base):
    """L1: the raw payload id must fullmatch what the writer stores; no sanitize-compare."""

    def test_control_valid_shape_matches(self):
        self.write('a.json', _bound('DONE', sess='ab'))
        self.assertIs(self.gate('ab'), True)

    def test_underscore_id_fails_closed_even_with_an_identical_record_id(self):
        self.write('a.json', _bound('DONE', sess='a_b'))
        self.assertIs(self.gate('a_b'), False)

    def test_underscore_id_does_not_collide_with_sanitized_record(self):
        self.write('a.json', _bound('DONE', sess='ab'))
        self.assertIs(self.gate('a_b'), False)

    def test_overlong_id_fails_closed(self):
        sid = 'a' * 65
        self.write('a.json', _bound('DONE', sess=sid))
        self.assertIs(self.gate(sid), False)

    def test_trailing_newline_id_fails_closed(self):
        self.write('a.json', _bound('DONE', sess='ab\n'))
        self.assertIs(self.gate('ab\n'), False)

    def test_non_str_and_empty_ids_fail_closed(self):
        self.write('a.json', _bound('DONE'))
        for bad in ('', None, 5, ['sess-1']):
            self.assertIs(self.gate(bad), False, repr(bad))


class TestTieBreak(_Base):
    """L2: equal mtimes -> any non-passing record at that mtime wins, whatever the names."""

    def _pair(self, done_name, blocked_name):
        t = time.time() - 600
        for name, status in ((done_name, 'DONE'), (blocked_name, 'BLOCKED')):
            p = self.write(name, _bound(status))
            os.utime(p, ns=(int(t * 1e9), int(t * 1e9)))

    def test_tie_blocked_sorts_after_done(self):
        self._pair('a-done.json', 'z-blocked.json')
        self.assertIs(self.gate(), False)

    def test_tie_blocked_sorts_before_done(self):
        self._pair('z-done.json', 'a-blocked.json')
        self.assertIs(self.gate(), False)

    def test_tie_between_two_passing_records_passes(self):
        t = time.time() - 600
        for name, status in (('a.json', 'DONE'), ('b.json', 'DONE_WITH_CONCERNS')):
            p = self.write(name, _bound(status))
            os.utime(p, ns=(int(t * 1e9), int(t * 1e9)))
        self.assertIs(self.gate(), True)

    def test_strictly_newer_done_still_beats_older_blocked(self):
        self.write('a.json', _bound('BLOCKED'), age_secs=900)
        self.write('b.json', _bound('DONE'), age_secs=60)
        self.assertIs(self.gate(), True)


class TestTtlSweepTrustBoundary(_Base):
    """L3."""

    OLD = 3 * 3600

    def test_control_real_dir_old_json_is_swept_fresh_kept(self):
        old = self.write('old.json', {'status': 'DONE'}, age_secs=self.OLD)
        fresh = self.write('fresh.json', {'status': 'DONE'}, age_secs=60)
        gg._ttl_sweep_agent_status()
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(fresh))

    def test_symlinked_status_dir_target_is_untouched(self):
        target = os.path.join(self.home, 'real-status')
        os.makedirs(target)
        old = self.write('old.json', {'status': 'DONE'}, age_secs=self.OLD, d=target)
        shutil.rmtree(self.status_dir)
        os.symlink(target, self.status_dir)
        gg._ttl_sweep_agent_status()
        self.assertTrue(os.path.exists(old), 'sweep followed a symlinked agent-status dir')

    def test_symlinked_entry_is_not_followed_or_removed(self):
        outside = self.write('outside.json', {'status': 'DONE'}, age_secs=self.OLD, d=self.home)
        link = os.path.join(self.status_dir, 'link.json')
        os.symlink(outside, link)
        gg._ttl_sweep_agent_status()
        self.assertTrue(os.path.exists(outside))
        self.assertTrue(os.path.islink(link))

    def test_env_claude_dir_is_ignored(self):
        decoy = os.path.join(self.home, 'decoy')
        os.makedirs(os.path.join(decoy, 'agent-status'))
        decoy_old = self.write('old.json', {'status': 'DONE'}, age_secs=self.OLD,
                               d=os.path.join(decoy, 'agent-status'))
        real_old = self.write('old.json', {'status': 'DONE'}, age_secs=self.OLD)
        with mock.patch.dict(os.environ, {'CLAUDE_DIR': decoy}):
            gg._ttl_sweep_agent_status()
        self.assertTrue(os.path.exists(decoy_old), 'sweep honoured env CLAUDE_DIR')
        self.assertFalse(os.path.exists(real_old))


class TestControlCharPathFailsClosed(_Base):
    """Embedded newline/control chars: the default `.*\\.env(\\..*)?$` pattern backtracks
    cubically on a newline (4096 chars ~ 24 s vs a 5 s hook timeout), so such paths must fail
    closed BEFORE any regex or realpath work."""

    def _audit_events(self):
        path = os.path.join(self.home, '.claude', 'logs', 'audit.jsonl')
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_4096_char_newline_path_is_blocked_fast(self):
        path = ('.env' * 1023) + '\nz'
        self.assertLessEqual(len(path), 4096)
        t0 = time.monotonic()
        code, msg = gg.evaluate('Write', {'file_path': path}, SESS)
        elapsed = time.monotonic() - t0
        self.assertEqual(code, 2, msg)
        self.assertIn('control characters', msg)
        self.assertLess(elapsed, 1.0, f'control-char path took {elapsed:.1f}s (regex backtracking?)')

    def test_control_char_path_that_no_policy_matches_is_still_blocked(self):
        for ch in ('\n', '\t', '\x00', '\x1f', '\x7f', '\r'):
            code, msg = gg.evaluate('Write', {'file_path': f'src/ok{ch}name.txt'}, SESS)
            self.assertEqual(code, 2, repr(ch))
            self.assertIn('[CAST-POLICY-BLOCK]', msg)

    def test_edit_tool_is_covered_too(self):
        code, _ = gg.evaluate('Edit', {'file_path': 'a\nb'}, SESS)
        self.assertEqual(code, 2)

    def test_override_allows_and_audits(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            code, msg = gg.evaluate('Write', {'file_path': 'src/ok\nname.txt'}, SESS)
        self.assertEqual((code, msg), (0, ''))
        self.assertIn('policy-path-control-chars',
                      [e.get('policy_id') for e in self._audit_events()])

    def test_ordinary_paths_are_unaffected(self):
        code, msg = gg.evaluate('Write', {'file_path': '/home/u/proj/src/app.py'}, SESS)
        self.assertEqual((code, msg), (0, ''))

    def test_empty_policy_list_does_not_block_on_control_chars(self):
        self.write('policies.json', {'policies': []}, d=os.path.join(self.home, '.claude', 'config'))
        code, msg = gg.evaluate('Write', {'file_path': 'a\nb'}, SESS)
        self.assertEqual((code, msg), (0, ''))


class TestResolvedCandidateFailsClosed(_Base):
    """The control-char / length checks must cover the symlink-RESOLVED candidate too: a short,
    control-free symlink can resolve to a long target with a non-final newline, and the regexes
    would then backtrack cubically on it (8.4 s at 3400 chars vs a 5 s hook timeout)."""

    def _link_to(self, target_dir):
        os.makedirs(target_dir, exist_ok=True)
        link = os.path.join(self.home, 'link')
        os.symlink(target_dir, link)
        return link

    def _audit_ids(self):
        log = os.path.join(self.home, '.claude', 'logs', 'audit.jsonl')
        if not os.path.exists(log):
            return []
        with open(log) as f:
            return [json.loads(line).get('policy_id') for line in f if line.strip()]

    def test_symlink_to_a_newline_target_is_blocked_fast(self):
        link = self._link_to(os.path.join(self.home, 'tgt', 'a\nb'))
        raw = link + '/x.txt'
        self.assertIsNone(gg._POLICY_CONTROL_CHAR_RE.search(raw))  # the RAW path is control-free
        for tool in ('Write', 'Edit'):
            t0 = time.monotonic()
            code, msg = gg.evaluate(tool, {'file_path': raw}, SESS)
            elapsed = time.monotonic() - t0
            self.assertEqual(code, 2, f'{tool}: resolved newline target was allowed')
            self.assertIn('symlink-resolved', msg)
            self.assertIn('control characters', msg)
            self.assertLess(elapsed, 1.0)

    def test_symlink_to_a_normal_target_is_unaffected(self):
        link = self._link_to(os.path.join(self.home, 'tgt', 'plain'))
        self.assertEqual(gg.evaluate('Write', {'file_path': link + '/x.txt'}, SESS), (0, ''))

    def test_override_allows_and_audits_the_resolved_case(self):
        link = self._link_to(os.path.join(self.home, 'tgt', 'a\nb'))
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            self.assertEqual(gg.evaluate('Write', {'file_path': link + '/x.txt'}, SESS), (0, ''))
        self.assertIn('policy-resolved-path-control-chars', self._audit_ids())

    def test_resolved_path_over_the_length_cap_is_blocked(self):
        # raw <= 4096 chars (allowed), resolved = a longer target + the same tail > 4096.
        target = os.path.join(self.home, 'd' * 200)
        link = self._link_to(target)
        room = gg._POLICY_MAX_PATH_LEN - len(link) - 1
        tail = (('a' * 99 + '/') * (room // 100 + 1))[:room - 1] + 'a'
        raw = link + '/' + tail
        self.assertLessEqual(len(raw), gg._POLICY_MAX_PATH_LEN)
        self.assertGreater(len(os.path.realpath(raw)), gg._POLICY_MAX_PATH_LEN)
        code, msg = gg.evaluate('Write', {'file_path': raw}, SESS)
        self.assertEqual(code, 2, msg)
        self.assertIn('symlink-resolved', msg)
        self.assertIn('too long', msg)

    def test_long_newline_resolved_candidate_never_reaches_the_regexes(self):
        # Linux can resolve to ~4095-char targets; macOS (PATH_MAX 1024) cannot, so simulate
        # the resolved candidate directly. Unguarded this is ~8 s and then ALLOWED.
        resolved = ('.env' * 850) + '\nz'
        self.assertLess(len(resolved), gg._POLICY_MAX_PATH_LEN)
        with mock.patch.object(gg.os.path, 'realpath', return_value=resolved):
            t0 = time.monotonic()
            code, msg = gg.evaluate('Write', {'file_path': 'src/ok.txt'}, SESS)
            elapsed = time.monotonic() - t0
        self.assertEqual(code, 2, msg)
        self.assertIn('symlink-resolved', msg)
        self.assertLess(elapsed, 1.0, f'resolved candidate took {elapsed:.1f}s (regex backtracking?)')


class TestNonStringPathFailsClosed(_Base):
    """A non-str file_path raised TypeError inside len()/re.search, which evaluate()'s blanket
    handler turned into ALLOW. A malformed Write/Edit target now fails closed."""

    BAD = (5, 0, 1.5, True, False, ['a'], [], {'a': 1}, {}, None)

    def test_non_string_file_path_is_blocked(self):
        for bad in self.BAD:
            for tool in ('Write', 'Edit'):
                code, msg = gg.evaluate(tool, {'file_path': bad}, SESS)
                self.assertEqual(code, 2, f'{tool} {bad!r}')
                self.assertIn('not a string', msg)
                self.assertIn('CAST_POLICY_OVERRIDE=1', msg)

    def test_missing_both_keys_is_blocked(self):
        for ti in ({}, {'content': 'x'}, 'not-a-dict', None):
            code, msg = gg.evaluate('Write', ti, SESS)
            self.assertEqual(code, 2, repr(ti))
            self.assertIn('missing or null', msg)

    def test_non_string_path_fallback_key_is_blocked(self):
        code, _ = gg.evaluate('Write', {'path': 5}, SESS)
        self.assertEqual(code, 2)

    def test_file_path_key_wins_over_path(self):
        # present-but-non-str file_path blocks even when `path` is a valid string
        code, _ = gg.evaluate('Write', {'file_path': 5, 'path': 'src/ok.txt'}, SESS)
        self.assertEqual(code, 2)

    def test_empty_string_path_is_still_no_path_no_policy(self):
        self.assertEqual(gg.evaluate('Write', {'file_path': ''}, SESS), (0, ''))
        self.assertEqual(gg.evaluate('Write', {'path': ''}, SESS), (0, ''))

    def test_valid_string_paths_behave_as_before(self):
        self.assertEqual(gg.evaluate('Write', {'file_path': 'src/ok.txt'}, SESS), (0, ''))
        code, msg = gg.evaluate('Write', {'path': '.github/workflows/x.yml'}, SESS)
        self.assertEqual(code, 2)
        self.assertIn('workflows-require-devops', msg)

    def test_non_write_tools_are_unaffected(self):
        self.assertEqual(gg.evaluate('Read', {'file_path': 5}, SESS), (0, ''))
        self.assertEqual(gg.evaluate('Bash', {'command': 'echo hi'}, SESS), (0, ''))

    def test_override_allows_and_audits(self):
        with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
            self.assertEqual(gg.evaluate('Write', {'file_path': 5}, SESS), (0, ''))
        log = os.path.join(self.home, '.claude', 'logs', 'audit.jsonl')
        with open(log) as f:
            ids = [json.loads(line).get('policy_id') for line in f if line.strip()]
        self.assertIn('policy-path-not-a-string', ids)


if __name__ == '__main__':
    unittest.main()
