#!/usr/bin/env python3
"""Linear-time tests for the Bash git guard (2026-10-06 security fix, High).

`scripts/cast-git-guard.py::evaluate("Bash")` was O(n^2) on repeated `git ` tokens: every
BLOCK pattern is anchored at `(^|\\s)git`, `re.search` retries that anchor at EVERY `git`
token, and each retry did O(rest-of-segment) work (a `(?=.*Y)` lookahead, or an option-run
walk). Measured before the fix, `("git " * N) + "; git push origin main"`: N=10k 2.5 s, 20k
11.5 s, 40k 41 s -- and ~100 KB of padding through the dispatcher took ~15 s. The PreToolUse
hook timeout is 5 s and a hook TIMEOUT is a non-blocking error, i.e. an ALLOW: ~60 KB of padding
in front of a raw `git push` bypassed the push / commit / reset blocks.

Three fixes are pinned here:
  1. `_flag_cluster` -- exact, linear rewrite of `-[a-zA-Z]*f[a-zA-Z]*`-style clusters (one long
     token like `-fff...f_` was O(n^2) INSIDE a single start).
  2. `_MAX_GIT_SCAN_WORK` -- a fail-closed bound on `(git tokens - 1) x segment length`, the
     quantity every repeated-start pattern scales with.
  3. `_GIT_MENTION` / `_MAX_GIT_SEGMENT_LEN` -- `shlex.split` is O(n^2) in its longest token, so
     non-git segments are not tokenised and an over-long git-mentioning segment is refused.

Every timing test runs under a SIGALRM tripwire (a BaseException, so `evaluate`'s own
`except Exception: return 0, ''` cannot swallow it): a regression FAILS in seconds instead of
hanging the suite for the 40+ s the unfixed guard needs.

HOME is redirected to a temp dir and `_record_hatch` is mocked: a hatched command never spawns
the audit subprocess or touches a real cast.db. Hyphenated filename loaded via importlib, same
pattern as tests/test_cast_git_guard_fail_closed.py.
"""
import importlib.util
import os
import re
import shutil
import signal
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent

_spec = importlib.util.spec_from_file_location(
    'cast_git_guard_perf', str(_REPO / 'scripts' / 'cast-git-guard.py'))
gg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gg)

G = 'gi' + 't'            # the verb is assembled so no literal guarded command sits in this file
BOUND_SECS = 1.0          # the contract: every padded command is decided in under a second
TRIPWIRE_SECS = 4.0       # a regressed guard is aborted here instead of running for 40+ s


class _TooSlow(BaseException):
    """BaseException on purpose: evaluate() ends in `except Exception: return 0, ''`."""


def _pad(n, unit=G + ' '):
    return unit * n


class _Timed(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-gitperf-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_PUSH_OK', 'CAST_COMMIT_AGENT', 'CAST_RESET_OK', 'CLAUDE_SUBPROCESS'):
            os.environ.pop(k, None)
        rec = mock.patch.object(gg, '_record_hatch')
        rec.start()
        self.addCleanup(rec.stop)

    def run_bash(self, cmd):
        """(code, msg, elapsed) for evaluate('Bash', cmd); fails the test past TRIPWIRE_SECS."""
        def _alarm(signum, frame):
            raise _TooSlow()
        have_alarm = hasattr(signal, 'setitimer') and hasattr(signal, 'SIGALRM')
        previous = signal.signal(signal.SIGALRM, _alarm) if have_alarm else None
        t0 = time.perf_counter()
        try:
            if have_alarm:
                signal.setitimer(signal.ITIMER_REAL, TRIPWIRE_SECS)
            code, msg = gg.evaluate('Bash', {'command': cmd})
        except _TooSlow:
            self.fail(f'git guard still running after {TRIPWIRE_SECS} s on a {len(cmd)}-char '
                      f'command (quadratic regression)')
        finally:
            if have_alarm:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
        return code, msg, time.perf_counter() - t0

    def assert_blocked_fast(self, cmd, why=''):
        code, msg, elapsed = self.run_bash(cmd)
        self.assertEqual(code, 2, f'{why}: not blocked: {msg!r}')
        self.assertLess(elapsed, BOUND_SECS, f'{why}: took {elapsed:.2f} s')
        return msg


class TestRepeatedGitTokensBeforeTheVerb(_Timed):
    """The reported bypass: padding of `git ` tokens ahead of a raw irreversible op."""

    def test_push_after_40000_git_tokens_blocks_under_a_second(self):
        self.assert_blocked_fast(_pad(40000) + '; ' + G + ' push origin main', 'push')

    def test_commit_after_40000_git_tokens_blocks_under_a_second(self):
        self.assert_blocked_fast(_pad(40000) + '; ' + G + ' commit -m x', 'commit')

    def test_reset_hard_after_40000_git_tokens_blocks_under_a_second(self):
        self.assert_blocked_fast(_pad(40000) + '; ' + G + ' reset --hard', 'reset --hard')

    def test_hatch_at_the_end_does_not_unblock_the_padded_command(self):
        # Over the work bound the whole command is refused; the trailing hatch is irrelevant.
        for op, hatch in (('push origin main', 'CAST_PUSH_OK=1'),
                          ('commit -m x', 'CAST_COMMIT_AGENT=1'),
                          ('reset --hard', 'CAST_RESET_OK=1')):
            self.assert_blocked_fast(
                _pad(40000) + '; ' + hatch + ' ' + G + ' ' + op, 'hatched ' + op)

    def test_under_the_bound_the_unhatched_earlier_push_still_blocks_on_its_own_merits(self):
        # 200 tokens x ~800 chars = 160k units: under _MAX_GIT_SCAN_WORK, so this is decided by
        # the real patterns, not by the bound. The hatch applies to ITS segment only.
        cmd = _pad(200) + 'push origin main; CAST_PUSH_OK=1 ' + G + ' push origin main'
        self.assertLessEqual(gg._scan_work(cmd.split(';')[0], 10 ** 9), gg._MAX_GIT_SCAN_WORK)
        msg = self.assert_blocked_fast(cmd, 'under-bound earlier push')
        self.assertIn('Raw `git push` blocked', msg)
        self.assertNotIn('far more `git` tokens', msg)

    def test_under_the_bound_a_hatched_push_alone_is_still_allowed(self):
        code, msg, _ = self.run_bash('CAST_PUSH_OK=1 ' + G + ' push origin main')
        self.assertEqual((code, msg), (0, ''))

    def test_padding_with_each_pattern_verb_cannot_stall_the_guard(self):
        # Each unit makes a DIFFERENT lookahead / option-run pattern pay per token (the 22 patterns
        # measured super-linear). ~100 KB each, a raw push at the end.
        units = ['branch ', 'checkout ', 'rm -f ', 'config ', 'switch ', 'update-ref ', 'gc ',
                 'worktree remove ', 'reset ', 'clean ', 'prune ', 'commit ', 'push ', 'stash ',
                 'reflog ', 'filter-branch ', 'restore ', '-c ', '-C ', '--no-pager ', '']
        for v in units:
            unit = G + ' ' + v
            self.assert_blocked_fast(
                unit * (100000 // len(unit)) + '; ' + G + ' push origin main', repr(unit))

    def test_many_tokens_split_across_segments_cannot_stall_the_guard(self):
        # 30 segments x 200 `git -c ` units (~1.4 KB): each is ~280k work units, under the
        # 400k bound ALONE (~0.14 s each unbounded), but together ~4 s -- only the CUMULATIVE
        # bound stops it.
        seg = _pad(200, G + ' -c ').strip()
        self.assertLess(gg._scan_work(seg, 10 ** 9), gg._MAX_GIT_SCAN_WORK)
        self.assert_blocked_fast('; '.join([seg] * 30) + '; ' + G + ' push origin main',
                                 'many segments')

    def test_quoted_git_tokens_are_counted_on_the_normalised_variant_too(self):
        # `'git' 'git' ...` has NO `git` token in the raw segment; shlex normalisation turns it
        # into 20000 real ones. The bound must look at the normalised rendering as well.
        self.assert_blocked_fast(("'" + G + "' ") * 20000 + '; ' + G + ' push origin main',
                                 'quoted tokens')


class TestSingleLongToken(_Timed):
    """One start, O(n^2) inside a token: `-[a-zA-Z]*f[a-zA-Z]*` + a terminator that fails."""

    def test_force_cluster_token_cannot_stall_checkout_switch_branch_rm(self):
        for verb, tok in (('checkout', '-' + 'f' * 100000 + '_'),
                          ('switch', '-' + 'f' * 100000 + '_'),
                          ('branch', '-' + 'D' * 100000 + '_'),
                          ('branch', '-' + 'M' * 100000 + '_'),
                          ('rm', '-' + 'n' * 100000 + '_ --force'),
                          ('clean', '-' + 'n' * 100000 + '_')):
            self.assert_blocked_fast(
                G + ' ' + verb + ' ' + tok + '; ' + G + ' push origin main', verb + ' ' + tok[:4])

    def test_flag_cluster_still_blocks_what_it_blocked(self):
        for cmd in (G + ' checkout -fb x', G + ' checkout -bf x', G + ' branch -D x',
                    G + ' branch -dD x', G + ' branch -M a b', G + ' rm -rf x', G + ' switch -f x',
                    G + ' worktree remove -f x'):
            code, _msg, _ = self.run_bash(cmd)
            self.assertEqual(code, 2, cmd)

    def test_flag_cluster_still_allows_what_it_allowed(self):
        for cmd in (G + ' checkout -b x', G + ' branch -d x', G + ' rm --cached -f x',
                    G + ' rm -n x', G + ' clean -nd', G + ' branch -a', G + ' status',
                    G + ' log --oneline -5'):
            code, msg, _ = self.run_bash(cmd)
            self.assertEqual((code, msg), (0, ''), cmd)


class TestShlexIsNotRunOnTokensItCannotUse(_Timed):

    def test_one_giant_non_git_segment_is_not_tokenised(self):
        # 1 MB single token, no `git` anywhere in it: shlex would need ~7 s; skipped entirely.
        code, _msg, elapsed = self.run_bash('echo ' + 'x' * 1000000 + '; ' + G + ' status')
        self.assertEqual(code, 0)
        self.assertLess(elapsed, BOUND_SECS)

    def test_a_giant_git_mentioning_segment_is_refused_not_tokenised(self):
        size = 250000        # fixed (not derived from the constant): a mutated cap must not OOM us
        msg = self.assert_blocked_fast(
            G + ' branch ' + 'x' * size + '; ' + G + ' status', 'giant git segment')
        self.assertIn('far more `git` tokens', msg)
        self.assertGreater(size, gg._MAX_GIT_SEGMENT_LEN)

    def test_the_bytes_handed_to_shlex_are_capped_cumulatively_across_segments(self):
        # HIGH-1 (security round 2): each segment is under the 200 KB per-segment cap, but shlex
        # costs ~0.3 s per 195 KB token, so FIVE of them ran the guard past the dispatcher's 2 s
        # watchdog (and, with `g\<newline>it` spellings, past a naming test that missed them).
        # Refused up front by the cumulative cap instead.
        seg = G + ' log ' + 'x' * 195000
        self.assertLess(len(seg), gg._MAX_GIT_SEGMENT_LEN)
        cmd = '; '.join([seg] * 5) + '; ' + G + ' push origin main'
        self.assertGreater(5 * len(seg), gg._MAX_GIT_TOKENIZE_BYTES)
        msg = self.assert_blocked_fast(cmd, '5 x 195 KB git segments')
        self.assertIn('add up to far more text', msg)       # the cap's message, not the push block

    def test_the_cumulative_cap_also_covers_continuation_spelled_git(self):
        # `g\<newline>it` joins to a git-mentioning segment before the cap sees it.
        seg = 'g\\\nit' + 'x' * 195000
        cmd = ';'.join([seg] * 8) + ';g\\\nit push origin main'
        msg = self.assert_blocked_fast(cmd, 'continuation-spelled git x 8')
        self.assertIn('add up to far more text', msg)

    def test_under_the_cumulative_cap_big_segments_are_still_decided_on_their_merits(self):
        seg = G + ' log ' + 'x' * 150000
        self.assertLessEqual(2 * len(seg), gg._MAX_GIT_TOKENIZE_BYTES)
        code, msg, _elapsed = self.run_bash(seg + '; ' + seg + '; ' + G + ' push origin main')
        self.assertEqual(code, 2)
        self.assertIn('Raw `git push` blocked', msg)         # reached the real verdict
        code, msg, _elapsed = self.run_bash(seg + '; ' + seg)
        self.assertEqual((code, msg), (0, ''))

    def test_non_git_segments_never_count_toward_the_cumulative_cap(self):
        code, _msg, elapsed = self.run_bash(';'.join(['echo ' + 'x' * 100000] * 10) + '; ' + G + ' status')
        self.assertEqual(code, 0)
        self.assertLess(elapsed, BOUND_SECS * 2)

    def test_git_mention_precheck_matches_every_spelling_normalisation_accepts(self):
        # _GIT_MENTION is a NECESSARY condition for `_normalize_git_segment` returning non-None:
        # shlex only deletes quote / backslash characters, so if the precheck misses a spelling
        # that shlex would turn into `git`, normalisation would be skipped -> a bypass.
        for seg in (G + ' push', "'" + G + "' push", '"' + G + '" push', 'g' + "'i't push",
                    'g\\it push', '/usr/bin/' + G + ' push', 'FOO=1 ' + G + ' push',
                    '"g""i""t" push', "g''i''t push", '\\g\\i\\t push', 'FOO="a b" ' + G + ' push'):
            self.assertIsNotNone(gg._GIT_MENTION.search(seg), seg)
        # And it is not a no-op: plain non-git words do not match.
        for seg in ('echo hello', 'ls -la', 'make test', 'rg "push" docs/'):
            self.assertIsNone(gg._GIT_MENTION.search(seg), seg)

    def test_precheck_never_skips_a_segment_normalisation_would_normalise(self):
        # Exhaustive small-scope check over an alphabet of the characters shlex treats specially
        # plus the letters of the word: whenever normalisation yields a rendering, the precheck
        # must have matched.
        alphabet = ['g', 'i', 't', "'", '"', '\\', ' ', 'x', '/']
        pending = ['']
        for _ in range(5):
            pending = [p + c for p in pending for c in alphabet]
            for seg in pending:
                if gg._normalize_git_segment(seg) is not None:
                    self.assertIsNotNone(gg._GIT_MENTION.search(seg), repr(seg))


class TestScanWork(unittest.TestCase):

    def test_zero_or_one_git_token_costs_nothing_however_long(self):
        self.assertEqual(gg._scan_work('echo hello', 100), 0)
        self.assertEqual(gg._scan_work(G + ' status ' + 'x' * 10 ** 6, 100), 0)
        self.assertEqual(gg._scan_work('x ' + G, 100), 0)

    def test_work_is_extra_git_tokens_times_length(self):
        v = G + ' a ' + G + ' b ' + G + ' c'
        self.assertEqual(gg._scan_work(v, 10 ** 9), 2 * len(v))

    def test_quoted_and_glued_tokens_are_not_start_tokens(self):
        self.assertEqual(gg._scan_work("'" + G + "' 'x" + G + "' " + G + 'x', 10 ** 9), 0)

    def test_stops_counting_once_over_the_limit(self):
        v = _pad(100000)
        self.assertEqual(gg._scan_work(v, 1000), 1001)

    def test_exactly_at_the_limit_is_not_over_it(self):
        v = G + ' ' + G                    # one extra token, length 7
        self.assertEqual(gg._scan_work(v, 7), 7)
        self.assertEqual(gg._scan_work(v, 6), 7)

    def test_the_bound_is_cumulative_across_segments(self):
        seg = G + ' a ' + G + ' b'          # 11 chars, one extra `git` token: work 11 per segment
        with mock.patch.object(gg, '_MAX_GIT_SCAN_WORK', 11 * 10):
            under = ';'.join([seg] * 10)    # exactly at the bound
            over = ';'.join([seg] * 11)     # one segment past it
            with mock.patch.object(gg, '_record_hatch'):
                self.assertEqual(gg._git_evaluate(under), (0, None))
                code, msg = gg._git_evaluate(over)
        self.assertEqual(code, 2)
        self.assertIn('far more `git` tokens', msg)


class TestFlagClusterIsVerdictIdentical(unittest.TestCase):
    """`_flag_cluster(letter)` must match EXACTLY what `-[a-zA-Z]*<letter>[a-zA-Z]*` matched,
    under both terminators the module uses (`\\b` and `(\\s|$)`). Exhaustive over every string
    of length <= 6 on an alphabet that includes the letter, other letters, `-`, `_`, digits,
    a non-ASCII word character and whitespace."""

    def test_equivalent_to_the_old_nested_star_form(self):
        for letter in ('f', 'D', 'M', 'n'):
            alphabet = [letter, 'x', '-', '_', '1', ' ', 'é']
            terminators = (r'\b', r'(\s|$)')
            old = [re.compile(r'(?:^|\s)-[a-zA-Z]*' + letter + r'[a-zA-Z]*' + t) for t in terminators]
            new = [re.compile(r'(?:^|\s)' + gg._flag_cluster(letter) + t) for t in terminators]
            pending = ['']
            for _ in range(6):
                pending = [p + c for p in pending for c in alphabet]
                for s in pending:
                    for o, n in zip(old, new):
                        mo, mn = o.search(s), n.search(s)
                        self.assertEqual(
                            (mo.span() if mo else None), (mn.span() if mn else None),
                            f'{letter!r} {s!r}')

    def test_adds_no_capture_group(self):
        # Numbered groups in the patterns that embed it must keep their numbering.
        self.assertEqual(re.compile(gg._flag_cluster('f')).groups, 0)


def _reference_join_continuations(command):
    """The ORIGINAL quadratic step 1 of `_scannable_segments`, verbatim (pre-2026-10-06). Pinned
    here as the oracle `_join_continuations` must equal on every input."""
    joined_lines = []
    buf = ''
    for line in command.split('\n'):
        buf += line
        trailing = 0
        idx = len(buf) - 1
        while idx >= 0 and buf[idx] == '\\':
            trailing += 1
            idx -= 1
        if trailing % 2 == 1:
            buf = buf[:len(buf) - trailing] + ('\\' * ((trailing - 1) // 2))
            continue
        joined_lines.append(buf)
        buf = ''
    if buf:
        joined_lines.append(buf)
    return joined_lines


class TestContinuationJoinIsLinearAndIdentical(_Timed):
    """M4 (security round 1): `("a\\\\\\n" * N) + "\\n" + <raw push>` was O(lines x length) in the
    join step: 0.85 s at 900 KB, >9 s at 4.8 MB."""

    def test_identical_to_the_original_on_every_string_over_a_tight_alphabet(self):
        import itertools
        for length in range(0, 9):
            for chars in itertools.product('\\a\n\r', repeat=length):
                c = ''.join(chars)
                self.assertEqual(gg._join_continuations(c), _reference_join_continuations(c), repr(c))

    def test_identical_to_the_original_on_random_inputs(self):
        import random
        rnd = random.Random(20261006)
        for _ in range(30000):
            c = ''.join(rnd.choice('\\\\\\a\n\r; |&') for _ in range(rnd.randint(0, 48)))
            self.assertEqual(gg._join_continuations(c), _reference_join_continuations(c), repr(c))

    def test_runs_of_backslashes_spanning_lines_keep_the_originals_semantics(self):
        for c in ('\\\\\\\n\\\n', '\\\n\\\n\\\n', 'a\\\\\\\n\n', '\\\n', 'a\\\n\n', '\\\\\n\\',
                  '\\\n\r\n\\\n', 'a\\\r\nb', '\n\n\n', ''):
            self.assertEqual(gg._join_continuations(c), _reference_join_continuations(c), repr(c))

    def test_scannable_segments_still_joins_a_continued_verb(self):
        self.assertEqual([s.strip() for s in gg._scannable_segments(G + ' \\\npush origin main')],
                         [G + ' push origin main'])

    def test_4_8_MB_of_continuation_lines_then_a_raw_push_is_blocked_under_a_second(self):
        cmd = ('a\\\n' * 1600000) + '\n' + G + ' push origin main'
        self.assertGreaterEqual(len(cmd), 4800000)
        msg = self.assert_blocked_fast(cmd, '4.8 MB continuations')
        self.assertIn('Raw `git push` blocked', msg)   # the real verdict, not a bound/timeout

    def test_the_join_alone_is_linear(self):
        t0 = time.perf_counter()
        gg._join_continuations('a\\\n' * 1600000)
        self.assertLess(time.perf_counter() - t0, BOUND_SECS)


class TestAuditSpawnsAreMemoisedPerCall(_Timed):
    """Security round 1: `_audit_push_hatch` / `_audit_commit_hatch` spawned one `git rev-parse`
    per hatched segment (uncapped), so ~500 hatched segments (13 KB) ran the guard past its
    watchdog budget. One spawn per distinct cwd per `_git_evaluate` call answers all of them."""

    def _count_spawns(self, cmd):
        calls = []

        def fake_run(argv, *a, **k):
            calls.append(list(argv))
            # `rev-parse --verify` rc 1 = "ref does not exist" -> update-ref is ALLOWED, so all
            # 500 segments are evaluated (rc 0 would block on the first and make the count vacuous).
            return mock.Mock(returncode=1 if '--verify' in argv else 0, stdout='/tmp/some-repo\n')
        with mock.patch.object(gg.subprocess, 'run', side_effect=fake_run):
            result = gg.evaluate('Bash', {'command': cmd})
        return result, calls

    def test_500_hatched_pushes_spawn_one_toplevel_lookup(self):
        (code, msg), calls = self._count_spawns(('CAST_PUSH_OK=1 ' + G + ' push x; ') * 500)
        self.assertEqual((code, msg), (0, ''))
        self.assertEqual(len([c for c in calls if 'rev-parse' in c]), 1, calls[:3])

    def test_500_hatched_commits_and_pushes_together_still_spawn_one(self):
        cmd = ('CAST_COMMIT_AGENT=1 ' + G + ' commit -m x; CAST_PUSH_OK=1 ' + G + ' push x; ') * 250
        (code, _msg), calls = self._count_spawns(cmd)
        self.assertEqual(code, 0)
        self.assertEqual(len([c for c in calls if 'rev-parse' in c]), 1)

    def test_500_update_ref_segments_naming_one_ref_spawn_one_verify(self):
        (_code, _msg), calls = self._count_spawns((G + ' update-ref refs/heads/x abc; ') * 500)
        self.assertEqual(len([c for c in calls if '--verify' in c]), 1)

    def test_the_memo_never_outlives_one_call(self):
        self._count_spawns(G + ' status')
        self.assertIsNone(gg._EVAL_MEMO)
        calls = []
        with mock.patch.object(gg.subprocess, 'run', side_effect=lambda argv, *a, **k:
                               calls.append(argv) or mock.Mock(returncode=0, stdout='/r\n')):
            gg._repo_toplevel()
            gg._repo_toplevel()                       # direct callers are never memoised
            gg.evaluate('Bash', {'command': 'CAST_PUSH_OK=1 ' + G + ' push x'})
            gg.evaluate('Bash', {'command': 'CAST_PUSH_OK=1 ' + G + ' push x'})
        self.assertEqual(len(calls), 4)               # 2 direct + 1 per evaluate (not shared)

    def test_the_memo_is_cleared_even_when_the_call_raises(self):
        with mock.patch.object(gg, '_git_evaluate_impl', side_effect=RuntimeError('x')):
            with self.assertRaises(RuntimeError):
                gg._git_evaluate('echo hi')
        self.assertIsNone(gg._EVAL_MEMO)


class TestCapSentinelIsNotEmittedWhileUnwindingABaseException(unittest.TestCase):
    """L1 (security round 1): the CAP sentinel is a `_record_hatch` subprocess (timeout 2 s); run
    in `finally` while the dispatcher's watchdog exception unwound, it added 2 s to a 2 s budget."""

    class _Alarm(BaseException):
        pass

    def _run(self, effect):
        def impl(command, suppressed_counter):
            suppressed_counter[0] = 3
            return effect()
        with mock.patch.object(gg, '_git_evaluate_impl', side_effect=impl), \
                mock.patch.object(gg, '_record_hatch') as rec:
            try:
                out = gg._git_evaluate('echo hi')
            except BaseException as exc:      # noqa: B036 - the point of the test
                out = exc
        return out, rec

    def test_normal_return_still_emits_it(self):
        out, rec = self._run(lambda: (0, None))
        self.assertEqual(out, (0, None))
        rec.assert_called_once()
        self.assertEqual(rec.call_args[0][0], 'CAST_HATCH_RECORD_CAP')

    def test_a_block_verdict_still_emits_it(self):
        out, rec = self._run(lambda: (2, 'blocked'))
        self.assertEqual(out, (2, 'blocked'))
        rec.assert_called_once()

    def test_an_ordinary_exception_still_emits_it(self):
        def boom():
            raise RuntimeError('x')
        out, rec = self._run(boom)
        self.assertIsInstance(out, RuntimeError)
        rec.assert_called_once()

    def test_a_base_exception_unwinding_does_not_emit_it(self):
        def alarm():
            raise self._Alarm()
        out, rec = self._run(alarm)
        self.assertIsInstance(out, self._Alarm)
        rec.assert_not_called()


if __name__ == '__main__':
    unittest.main()
