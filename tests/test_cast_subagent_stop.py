#!/usr/bin/env python3
"""Tests for scripts/cast_subagent_stop.py — fail-closed redaction breadcrumb.

Covers the FIX 2 breadcrumb added to _redact_fail_closed(): on a forced
redaction failure, the ~/.claude/logs/hook-errors.log line must contain the
input byte length and the failing exception's class name (or "none" when
nothing raised), and must NEVER contain any fragment of the input text. Two
2026-07-02 incidents landed with resolution_status='open' and were never
root-caused because the prior log line ("WARN: redaction failed — storing
[REDACTION_FAILED] marker") carried no other detail — it overwrote both
problem_summary and fix_summary with the same content-free marker.

HOME is redirected to an isolated temp dir for every test in this file (the
Python-test analogue of the BATS setup_temp_home/teardown_temp_home HARD RULE)
so hook-errors.log is never written under the real ~/.claude — os.path.expanduser
honors the HOME env var on POSIX, which is exactly what _log_error relies on.
"""
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_subagent_stop as css  # noqa: E402


class _IsolatedHomeTestCase(unittest.TestCase):
    """Redirects HOME to an isolated temp dir so _log_error's hardcoded
    ~/.claude/logs/hook-errors.log target never touches the real home dir."""

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-subagent-stop-test-')
        os.environ['HOME'] = self._tmpdir

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _read_log(self) -> str:
        log_path = os.path.join(self._tmpdir, '.claude', 'logs', 'hook-errors.log')
        if not os.path.isfile(log_path):
            return ''
        with open(log_path) as f:
            return f.read()


class TestRedactFailClosedBreadcrumb(_IsolatedHomeTestCase):

    def test_forced_failure_logs_byte_length_and_exception_class(self):
        secret_text = 'SECRET_MARKER_should_never_appear_in_the_log_12345'
        with mock.patch.object(
            css, '_redact_excerpt_verbose', return_value=(None, 'RuntimeError')
        ):
            out = css._redact_fail_closed(secret_text, site='problem_summary')

        self.assertEqual(out, '[REDACTION_FAILED]')
        log_content = self._read_log()
        self.assertIn('site=problem_summary', log_content)
        self.assertIn(f'input_bytes={len(secret_text.encode("utf-8"))}', log_content)
        self.assertIn('exception=RuntimeError', log_content)

    def test_breadcrumb_never_contains_input_content(self):
        secret_text = 'SECRET_MARKER_should_never_appear_in_the_log_12345'
        with mock.patch.object(
            css, '_redact_excerpt_verbose', return_value=(None, 'RuntimeError')
        ):
            css._redact_fail_closed(secret_text, site='fix_summary')

        log_content = self._read_log()
        self.assertNotIn('SECRET_MARKER', log_content)
        self.assertNotIn(secret_text, log_content)

    def test_no_exception_case_logs_exception_none(self):
        """redact_excerpt can fail with NO captured exception (e.g. the redact
        subprocess ran but returned empty output) — the breadcrumb must say so
        honestly rather than fabricating a class name."""
        with mock.patch.object(css, '_redact_excerpt_verbose', return_value=(None, None)):
            out = css._redact_fail_closed('some text', site='problem_summary')

        self.assertEqual(out, '[REDACTION_FAILED]')
        self.assertIn('exception=none', self._read_log())

    def test_empty_string_redaction_result_also_fails_closed(self):
        """redact_excerpt returning '' (not just None) is also a failure."""
        with mock.patch.object(css, '_redact_excerpt_verbose', return_value=('', None)):
            out = css._redact_fail_closed('some text', site='fix_summary')

        self.assertEqual(out, '[REDACTION_FAILED]')
        self.assertIn('site=fix_summary', self._read_log())

    def test_successful_redaction_does_not_log_or_use_marker(self):
        with mock.patch.object(
            css, '_redact_excerpt_verbose', return_value=('redacted ok', None)
        ):
            out = css._redact_fail_closed('some text', site='problem_summary')

        self.assertEqual(out, 'redacted ok')
        self.assertEqual(self._read_log(), '')

    def test_empty_text_passthrough_no_log(self):
        out = css._redact_fail_closed('', site='problem_summary')
        self.assertEqual(out, '')
        self.assertEqual(self._read_log(), '')

    def test_breadcrumb_construction_failure_never_raises(self):
        """A pathological exception-name object (or any breadcrumb-construction
        hiccup) must not propagate — this path is already an error path."""

        class _Unstringable:
            def __format__(self, spec):
                raise ValueError('boom')

        with mock.patch.object(
            css, '_redact_excerpt_verbose', return_value=(None, _Unstringable())
        ):
            try:
                out = css._redact_fail_closed('some text', site='problem_summary')
            except Exception as exc:  # the assertion below is the real check
                self.fail(f'_redact_fail_closed raised: {exc!r}')
        self.assertEqual(out, '[REDACTION_FAILED]')


class TestRedactExcerptVerboseWrapping(_IsolatedHomeTestCase):
    """Light regression coverage for the redact_excerpt refactor: the public
    wrapper's return contract (Optional[str], identical behavior to before this
    fix split it into a verbose+thin-wrapper pair) must be unchanged."""

    def test_empty_text_passthrough(self):
        self.assertEqual(css.redact_excerpt(''), '')

    def test_wrapper_discards_exception_name(self):
        with mock.patch.object(
            css, '_redact_excerpt_verbose', return_value=('redacted', 'SomeError')
        ):
            self.assertEqual(css.redact_excerpt('x'), 'redacted')

    def test_wrapper_returns_none_on_total_failure(self):
        with mock.patch.object(
            css, '_redact_excerpt_verbose', return_value=(None, 'SomeError')
        ):
            self.assertIsNone(css.redact_excerpt('x'))


if __name__ == '__main__':
    unittest.main()
