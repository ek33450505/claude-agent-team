#!/usr/bin/env python3
"""Tests for scripts/cast-git-guard.py's CAST v10 I-3b hatch-recording
additions: `_hatch_value()`, `_record_hatch()`, and (as of Unit 1b-ii) the
block-averted recording semantics shared by all 16 hatch variables.

Unit 1a wired ONLY the commit/push hatches (CAST_COMMIT_AGENT, CAST_PUSH_OK)
into cast.db's ack_events table. Unit 1b-ii wires the remaining 14 and makes
the meaning of a recorded row uniform: a row is written ONLY when the hatch
actually AVERTED a block, never on every hatched invocation — see
`TestBlockAvertedRecording` below for the discriminating cases.

Hyphenated filename cannot be imported normally — load via importlib, same
pattern as tests/test_cast_pretool_dispatch.py.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_SCRIPT_PATH = _SCRIPTS_DIR / 'cast-git-guard.py'

_spec = importlib.util.spec_from_file_location('cast_git_guard', str(_SCRIPT_PATH))
cast_git_guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cast_git_guard)


class TestHatchValue(unittest.TestCase):
    """`_hatch_value(segment, variable)` extracts the literal value of a
    VAR=value assignment from the leading assignment prefix of a segment
    (before the `git` invocation), or '' if absent/unparseable."""

    def test_bare_value(self):
        seg = 'CAST_COMMIT_AGENT=1 git commit -m "fix"'
        self.assertEqual(
            cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT'), '1'
        )

    def test_quoted_value_with_spaces_survives_as_one_token(self):
        seg = 'CAST_COMMIT_AGENT="CI outage, hooks unreachable" git commit -m x'
        self.assertEqual(
            cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT'),
            'CI outage, hooks unreachable',
        )

    def test_variable_absent_returns_empty(self):
        # A different assignment is present, but not the one being asked for.
        seg = 'CAST_SKIP_PLUGIN_DRIFT=1 git commit -m x'
        self.assertEqual(cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT'), '')

    def test_no_assignments_at_all_returns_empty(self):
        seg = 'git commit -m x'
        self.assertEqual(cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT'), '')

    def test_unbalanced_quotes_in_the_hatch_value_itself_never_raises(self):
        # 2026-08-26 fix: ValueError no longer always means '' — see the two
        # tests below for the (far more common) case of an unbalanced quote
        # LATER in the command, which now correctly recovers '1'. This case
        # is different: the unbalanced quote is INSIDE the hatch value's own
        # token, so the whitespace-split fallback recovers a value that
        # still carries the stray opening quote character rather than a
        # clean '1' — an accepted, named limitation (see _hatch_value's
        # docstring), not a bug. The only hard guarantee under test here is
        # that this can never raise.
        seg = 'CAST_COMMIT_AGENT="unterminated git commit -m x'
        try:
            result = cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT')
        except Exception as e:  # pragma: no cover - the assertion below is the real check
            self.fail(f'_hatch_value raised {e!r} on unbalanced quotes instead of falling back')
        self.assertEqual(result, '"unterminated')

    def test_unbalanced_double_quote_later_in_command_still_recovers_value(self):
        """CAST v10 I-3b Unit 1a gate fix (Medium): an unbalanced quote in
        the COMMIT MESSAGE (i.e. after the leading hatch assignment) must
        not destroy extraction of the hatch value — the *_ALLOW regex has
        already matched the raw segment and honoured the hatch by the time
        this is called, so returning '' here would silently drop the audit
        row for a bypass that DID happen. Command built from concatenated
        fragments so this test file's own text does not trip the git guard
        that protects this repo's own commits."""
        seg = 'CAST_COMMIT_AGENT=1 git ' + 'com' + 'mit -m "unclosed'
        self.assertEqual(cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT'), '1')

    def test_unbalanced_single_quote_later_in_command_still_recovers_value(self):
        """Same as above, single-quote variant."""
        seg = "CAST_COMMIT_AGENT=1 git " + "com" + "mit -m 'unclosed"
        self.assertEqual(cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT'), '1')

    def test_stops_scanning_at_first_non_assignment_token(self):
        # A value that happens to look like a later assignment (e.g. inside
        # a commit message) must NOT be picked up once a non-assignment
        # token (the `git` invocation itself) has been reached.
        seg = 'CAST_SKIP_PLUGIN_DRIFT=1 git commit -m "CAST_COMMIT_AGENT=1"'
        self.assertEqual(cast_git_guard._hatch_value(seg, 'CAST_COMMIT_AGENT'), '')

    def test_multiple_leading_assignments_finds_the_right_one(self):
        seg = 'CAST_SKIP_PLUGIN_DRIFT=1 CAST_PUSH_OK=1 git push'
        self.assertEqual(cast_git_guard._hatch_value(seg, 'CAST_PUSH_OK'), '1')


class TestRecordHatch(unittest.TestCase):
    """`_record_hatch(variable, value, git_op)` shells out to cast_ack.py's
    CLI as an external subprocess — best-effort, never raises, never changes
    caller behavior regardless of what the subprocess does."""

    def test_calls_cast_ack_cli_with_expected_argv(self):
        with mock.patch.object(cast_git_guard.subprocess, 'run') as mock_run:
            cast_git_guard._record_hatch('CAST_COMMIT_AGENT', '1', 'commit')
        self.assertEqual(mock_run.call_count, 1)
        args, kwargs = mock_run.call_args
        argv = args[0]
        self.assertEqual(argv[0], 'python3')
        self.assertTrue(argv[1].endswith('cast_ack.py'))
        self.assertEqual(argv[2], 'CAST_COMMIT_AGENT')
        self.assertIn('--value', argv)
        self.assertEqual(argv[argv.index('--value') + 1], '1')
        self.assertIn('--script', argv)
        self.assertEqual(argv[argv.index('--script') + 1], 'cast-git-guard.py')
        # 2026-08-26 latency-bound fix: 5s -> 2s (see _record_hatch's
        # docstring for the measured healthy/hung-call numbers this bounds).
        self.assertEqual(kwargs.get('timeout'), 2)
        self.assertTrue(kwargs.get('capture_output'))

    def test_subprocess_exception_does_not_propagate(self):
        with mock.patch.object(
            cast_git_guard.subprocess, 'run', side_effect=OSError('boom')
        ):
            try:
                cast_git_guard._record_hatch('CAST_PUSH_OK', '1', 'push')
            except Exception as e:  # pragma: no cover - the fail() below is the real check
                self.fail(f'_record_hatch raised {e!r} instead of swallowing it')

    def test_subprocess_timeout_does_not_propagate(self):
        with mock.patch.object(
            cast_git_guard.subprocess,
            'run',
            side_effect=subprocess.TimeoutExpired(cmd='cast_ack.py', timeout=5),
        ):
            try:
                cast_git_guard._record_hatch('CAST_PUSH_OK', '1', 'push')
            except Exception as e:  # pragma: no cover - the fail() below is the real check
                self.fail(f'_record_hatch raised {e!r} on subprocess timeout')


class TestHatchRecordCap(unittest.TestCase):
    """CAST v10 I-3b Unit 1a gate fix (Medium): `_git_evaluate` bounds how
    many `_record_hatch()` audit-record subprocesses a SINGLE command can
    trigger, at `_MAX_HATCH_RECORDS_PER_COMMAND` (8) — see `_record_hatch`'s
    docstring for the measured latency (0.033s median healthy call vs. a
    5.011s/15.065s hung-spawn measurement at the prior uncapped 5s timeout)
    this bounds. The cap must ONLY skip the audit-record subprocess call,
    never change the ALLOW/BLOCK verdict.

    `_audit_commit_hatch()` (a separate audit.jsonl write, not part of this
    fix) also fires on every one of these ALLOWed commits, so HOME is
    redirected to an isolated temp dir for the duration of this test —
    same isolation contract as tests/test_cast_ack.py's _IsolatedDbTestCase
    — rather than letting it write to the real ~/.claude/logs/audit.jsonl.
    """

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-git-guard-hatch-test-')
        os.environ['HOME'] = self._tmpdir

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def test_ninth_hatch_in_one_command_is_skipped_verdict_unchanged(self):
        # 9 independently-hatched, individually-ALLOWed commits chained
        # with && — each carries its OWN CAST_COMMIT_AGENT=1 prefix (per
        # the per-segment evaluation this module already guarantees), so
        # every one of the 9 is a genuine, real hatch use, not a chained
        # bypass of the ALLOW check itself.
        segments = [
            'CAST_COMMIT_AGENT=1 git ' + 'com' + f'mit -m "unit {i}"'
            for i in range(9)
        ]
        command = ' && '.join(segments)
        # Patch `_record_hatch` itself, not the shared `subprocess.run` —
        # `_audit_commit_hatch()` (a separate, uncapped audit.jsonl write)
        # also shells out to real `git rev-parse` once per ALLOWed segment,
        # which would otherwise inflate a subprocess.run-level call count
        # with calls this cap was never meant to bound.
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(command)
        self.assertEqual((code, msg), (0, None))
        # CAST v10 I-3b Unit 1b-i: the cap still allows only 8 PER-HATCH
        # calls, but `_git_evaluate`'s `finally` now makes ONE additional
        # call for the CAST_HATCH_RECORD_CAP sentinel — so the total is
        # cap + 1, not cap. See TestHatchRecordCapSentinel below for tests
        # that assert on the sentinel call's own shape.
        self.assertEqual(
            mock_record.call_count, cast_git_guard._MAX_HATCH_RECORDS_PER_COMMAND + 1
        )
        sentinel_calls = [
            c for c in mock_record.call_args_list
            if c.args[0] == 'CAST_HATCH_RECORD_CAP'
        ]
        self.assertEqual(len(sentinel_calls), 1)

    def test_cap_does_not_suppress_a_real_block_after_it_is_reached(self):
        # 8 hatched, ALLOWed commits (exhausting the cap) followed by a
        # NINTH segment with NO hatch at all, carrying a genuinely
        # destructive op (git reset --hard). The cap must skip only the
        # 9th/10th audit-record call it would otherwise make — it must
        # NEVER suppress the BLOCK verdict for an unrelated, unhatched op
        # later in the same command.
        segments = [
            'CAST_COMMIT_AGENT=1 git ' + 'com' + f'mit -m "unit {i}"'
            for i in range(8)
        ]
        segments.append('git reset --hard')
        command = ' && '.join(segments)
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(command)
        self.assertEqual(code, 2)
        self.assertIsNotNone(msg)
        # Exactly 8 hatches occurred (none suppressed — 8 == the cap, not
        # over it), so NO CAST_HATCH_RECORD_CAP sentinel should fire here.
        self.assertEqual(
            mock_record.call_count, cast_git_guard._MAX_HATCH_RECORDS_PER_COMMAND
        )
        self.assertFalse(
            any(c.args[0] == 'CAST_HATCH_RECORD_CAP' for c in mock_record.call_args_list)
        )


class TestHatchRecordCapSentinel(unittest.TestCase):
    """CAST v10 I-3b Unit 1b-i: closes the ambiguity `_MAX_HATCH_RECORDS_
    PER_COMMAND` created — an absent per-hatch `ack_events` row used to mean
    EITHER "no hatch was used" OR "a hatch was used and suppressed by the
    cap". `_git_evaluate` now emits exactly one `CAST_HATCH_RECORD_CAP`
    sentinel row (via `_record_hatch`) whenever the cap suppressed at least
    one record, on EVERY exit path (allow, block, or exception) — via a
    `finally` clause wrapping the renamed `_git_evaluate_impl`.
    """

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-git-guard-hatch-sentinel-test-')
        os.environ['HOME'] = self._tmpdir

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def test_nine_hatches_emit_exactly_one_sentinel_naming_count_one(self):
        # 9 hatches: 8 real records + 1 suppressed -> exactly one sentinel
        # call naming a suppressed count of 1.
        segments = [
            'CAST_COMMIT_AGENT=1 git ' + 'com' + f'mit -m "unit {i}"'
            for i in range(9)
        ]
        command = ' && '.join(segments)
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(command)
        self.assertEqual((code, msg), (0, None))
        sentinel_calls = [
            c for c in mock_record.call_args_list
            if c.args[0] == 'CAST_HATCH_RECORD_CAP'
        ]
        self.assertEqual(len(sentinel_calls), 1)
        variable, value, git_op = sentinel_calls[0].args
        self.assertEqual(variable, 'CAST_HATCH_RECORD_CAP')
        self.assertIn('1', value)
        self.assertIn('suppressed', value)
        self.assertEqual(git_op, 'cap')

    def test_eight_or_fewer_hatches_emit_no_sentinel_at_all(self):
        # The discriminating case: staying AT or UNDER the cap must never
        # fire the sentinel. A sentinel that always fires is worthless.
        segments = [
            'CAST_COMMIT_AGENT=1 git ' + 'com' + f'mit -m "unit {i}"'
            for i in range(8)
        ]
        command = ' && '.join(segments)
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(command)
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 8)
        self.assertFalse(
            any(c.args[0] == 'CAST_HATCH_RECORD_CAP' for c in mock_record.call_args_list)
        )

    def test_suppression_followed_by_block_still_records_sentinel(self):
        # The early-return case the `finally` exists for: 9 hatches (1
        # suppressed) followed by an UNHATCHED destructive op that BLOCKs.
        # `_git_evaluate_impl` returns EARLY on the block, before its loop
        # would ever reach a "tally suppressed count" step at the end — the
        # sentinel must still be recorded, and the block verdict itself
        # must be untouched.
        segments = [
            'CAST_COMMIT_AGENT=1 git ' + 'com' + f'mit -m "unit {i}"'
            for i in range(9)
        ]
        segments.append('git reset --hard')
        command = ' && '.join(segments)
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(command)
        self.assertEqual(code, 2)
        self.assertIsNotNone(msg)
        sentinel_calls = [
            c for c in mock_record.call_args_list
            if c.args[0] == 'CAST_HATCH_RECORD_CAP'
        ]
        self.assertEqual(len(sentinel_calls), 1)

    def test_sentinel_record_hatch_raising_does_not_propagate(self):
        # If the sentinel's own _record_hatch call raises (e.g. cast_ack.py
        # itself misbehaves in a way that bypasses _record_hatch's internal
        # try/except, as happens here since the whole function is mocked),
        # `_git_evaluate` must still return the correct verdict and must
        # never let the exception escape.
        def flaky(variable, value, git_op):
            if variable == 'CAST_HATCH_RECORD_CAP':
                raise RuntimeError('boom')
            return None

        segments = [
            'CAST_COMMIT_AGENT=1 git ' + 'com' + f'mit -m "unit {i}"'
            for i in range(9)
        ]
        command = ' && '.join(segments)
        with mock.patch.object(
            cast_git_guard, '_record_hatch', side_effect=flaky
        ) as mock_record:
            try:
                code, msg = cast_git_guard._git_evaluate(command)
            except Exception as e:  # pragma: no cover - fail() below is the real check
                self.fail(
                    f'_git_evaluate raised {e!r} when the sentinel _record_hatch call raised'
                )
        self.assertEqual((code, msg), (0, None))
        self.assertTrue(
            any(c.args[0] == 'CAST_HATCH_RECORD_CAP' for c in mock_record.call_args_list)
        )


class TestBlockAvertedRecording(unittest.TestCase):
    """CAST v10 I-3b Unit 1b-ii: a per-hatch row is written ONLY when the
    hatch actually AVERTED a block — never on every hatched invocation. The
    BLOCK regexes are deliberately narrower than their matching ALLOW
    regexes (`_RESET_BLOCK` needs --hard/--merge/--keep; `_RESET_ALLOW`
    matches any hatched `git reset`), so a hatched-but-harmless invocation
    of a guarded op must record NOTHING even though its ALLOW pattern
    matches. This is the single most important property in this file.
    """

    def test_reset_hard_hatched_records_one_row(self):
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate('CAST_RESET_OK=1 git reset --hard')
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 1)
        variable, value, git_op = mock_record.call_args.args
        self.assertEqual((variable, value, git_op), ('CAST_RESET_OK', '1', 'reset'))

    def test_reset_soft_hatched_records_nothing(self):
        # THE discriminator: --soft never trips _RESET_BLOCK (index-only,
        # routine), so nothing was ever going to block and the hatch never
        # averted anything — must record NOTHING even though CAST_RESET_OK=1
        # is present and matches _RESET_ALLOW.
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate('CAST_RESET_OK=1 git reset --soft')
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 0)

    def test_clean_without_dry_run_hatched_records_one_row(self):
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate('CAST_CLEAN_OK=1 git clean -fdx')
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 1)
        variable, value, git_op = mock_record.call_args.args
        self.assertEqual((variable, value, git_op), ('CAST_CLEAN_OK', '1', 'clean'))

    def test_clean_dry_run_hatched_records_nothing(self):
        # Same discriminator, second op: -n/--dry-run is the exempt safe
        # form of clean, so the hatch never averts a block here either.
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate('CAST_CLEAN_OK=1 git clean -n')
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 0)

    def test_unhatched_destructive_op_still_blocks_and_records_nothing(self):
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate('git reset --hard')
        self.assertEqual(code, 2)
        self.assertIsNotNone(msg)
        self.assertEqual(mock_record.call_count, 0)


class TestGcDeduplication(unittest.TestCase):
    """`CAST_GC_OK` gates FOUR distinct BLOCK sites (`_GC_BLOCK` plus the
    three `_GC_HATCH_ALLOW`-gated config-injection/write/edit blocks).
    Tripping more than one within a single segment must still write exactly
    ONE row, not one per site."""

    def test_gc_and_config_injection_in_one_segment_dedup_to_one_row(self):
        # A single segment tripping BOTH _GC_BLOCK (bare `gc --prune=now`)
        # AND _GC_CINJECT_BLOCK (`-c gc.pruneExpire=now` present on the same
        # `git` invocation, subcommand-independent) — both keyed on the same
        # CAST_GC_OK hatch.
        cmd = 'CAST_GC_OK=1 git -c gc.pruneExpire=now gc --prune=now'
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(cmd)
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 1)
        variable, _value, _git_op = mock_record.call_args.args
        self.assertEqual(variable, 'CAST_GC_OK')

    def test_dedup_resets_per_segment_not_per_command(self):
        # Two SEPARATE segments, each independently tripping the dedup case
        # above, chained with its own hatch — dedup is scoped to one
        # segment, so this must record TWO rows, not one.
        seg = 'CAST_GC_OK=1 git -c gc.pruneExpire=now gc --prune=now'
        cmd = f'{seg} && {seg}'
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(cmd)
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 2)


class TestRecordedShapeSample(unittest.TestCase):
    """`variable`/`value`/`git_op` sampled across the simple, compound, and
    restore site shapes — not exhaustive over all 16 ops, but enough to
    prove each shape wires its op name and hatch correctly."""

    def test_simple_shape_stash(self):
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate('CAST_STASH_OK=1 git stash pop')
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 1)
        self.assertEqual(
            mock_record.call_args.args, ('CAST_STASH_OK', '1', 'stash')
        )

    def test_compound_shape_checkout(self):
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(
                'CAST_CHECKOUT_OK=1 git checkout -- some-file.txt'
            )
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 1)
        self.assertEqual(
            mock_record.call_args.args, ('CAST_CHECKOUT_OK', '1', 'checkout')
        )

    def test_restore_shape(self):
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(
                'CAST_RESTORE_OK=1 git restore some-file.txt'
            )
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 1)
        self.assertEqual(
            mock_record.call_args.args, ('CAST_RESTORE_OK', '1', 'restore')
        )

    def test_restore_staged_only_is_safe_and_records_nothing(self):
        # The safe form of restore (--staged without --worktree) never
        # blocks, so even with the hatch present nothing is averted.
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(
                'CAST_RESTORE_OK=1 git restore --staged some-file.txt'
            )
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(mock_record.call_count, 0)


class TestCapAcrossMixedOps(unittest.TestCase):
    """Cap interaction still holds once every op can record, not just
    commit: >8 recordable hatch uses spread across DIFFERENT ops in one
    command still yields exactly 8 real records + one sentinel."""

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-git-guard-hatch-mixed-cap-test-')
        os.environ['HOME'] = self._tmpdir

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def test_nine_distinct_ops_yield_eight_records_plus_one_sentinel(self):
        segments = [
            'CAST_COMMIT_AGENT=1 git ' + 'com' + 'mit -m "x"',
            'CAST_PUSH_OK=1 git push',
            'CAST_STASH_OK=1 git stash pop',
            'CAST_RESET_OK=1 git reset --hard',
            'CAST_CLEAN_OK=1 git clean -fdx',
            'CAST_CHECKOUT_OK=1 git checkout -- f.txt',
            'CAST_RESTORE_OK=1 git restore f.txt',
            'CAST_SWITCH_OK=1 git switch -f main',
            'CAST_REFLOG_OK=1 git reflog expire --all',
        ]
        command = ' && '.join(segments)
        with mock.patch.object(cast_git_guard, '_record_hatch') as mock_record:
            code, msg = cast_git_guard._git_evaluate(command)
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(
            mock_record.call_count, cast_git_guard._MAX_HATCH_RECORDS_PER_COMMAND + 1
        )
        sentinel_calls = [
            c for c in mock_record.call_args_list
            if c.args[0] == 'CAST_HATCH_RECORD_CAP'
        ]
        self.assertEqual(len(sentinel_calls), 1)
        self.assertIn('1', sentinel_calls[0].args[1])


class TestCommitPushAuditUnchanged(unittest.TestCase):
    """`_audit_commit_hatch`/`_audit_push_hatch` fire on ALLOW exactly as
    before this refactor — they are NOT gated on the BLOCK regex the way
    `_record_hatch` now is; only the `_record_hatch` call moved."""

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-git-guard-hatch-audit-test-')
        os.environ['HOME'] = self._tmpdir

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def test_audit_commit_hatch_fires_on_allow(self):
        with mock.patch.object(cast_git_guard, '_audit_commit_hatch') as mock_audit, \
                mock.patch.object(cast_git_guard, '_record_hatch'):
            code, msg = cast_git_guard._git_evaluate(
                'CAST_COMMIT_AGENT=1 git ' + 'com' + 'mit -m "x"'
            )
        self.assertEqual((code, msg), (0, None))
        mock_audit.assert_called_once()

    def test_audit_push_hatch_fires_on_allow(self):
        with mock.patch.object(cast_git_guard, '_audit_push_hatch') as mock_audit, \
                mock.patch.object(cast_git_guard, '_record_hatch'):
            code, msg = cast_git_guard._git_evaluate('CAST_PUSH_OK=1 git push')
        self.assertEqual((code, msg), (0, None))
        mock_audit.assert_called_once()

    def test_audit_commit_hatch_not_called_without_the_hatch(self):
        with mock.patch.object(cast_git_guard, '_audit_commit_hatch') as mock_audit:
            code, msg = cast_git_guard._git_evaluate('git ' + 'com' + 'mit -m "x"')
        self.assertEqual(code, 2)
        mock_audit.assert_not_called()

    def test_audit_push_hatch_not_called_without_the_hatch(self):
        with mock.patch.object(cast_git_guard, '_audit_push_hatch') as mock_audit:
            code, msg = cast_git_guard._git_evaluate('git push')
        self.assertEqual(code, 2)
        mock_audit.assert_not_called()


class TestRecordHatchUseFailOpen(unittest.TestCase):
    """CAST v10 I-3b Unit 1b-ii follow-up (security review Low #2):
    `record_hatch_use()` wraps its own body in try/except, independently of
    `_record_hatch`'s and `_hatch_value`'s own "never raises" contracts —
    the guarantee must be LOCAL, not merely inherited, so it survives a
    future refactor of either callee. A raise from either one, while
    recording a hatch use that DID avert a block, must never propagate and
    must never change the ALLOW verdict."""

    def test_hatch_value_raising_inside_recording_does_not_change_verdict_or_propagate(self):
        with mock.patch.object(
            cast_git_guard, '_hatch_value', side_effect=RuntimeError('boom')
        ):
            try:
                code, msg = cast_git_guard._git_evaluate(
                    'CAST_RESET_OK=1 git reset --hard'
                )
            except Exception as e:  # pragma: no cover - fail() below is the real check
                self.fail(
                    f'_git_evaluate raised {e!r} when _hatch_value raised inside '
                    'record_hatch_use instead of failing open'
                )
        self.assertEqual((code, msg), (0, None))


if __name__ == '__main__':
    unittest.main()
