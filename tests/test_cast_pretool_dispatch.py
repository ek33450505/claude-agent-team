#!/usr/bin/env python3
"""Tests for scripts/cast-pretool-dispatch.py — dispatch_decisions redaction
breadcrumb.

Covers the FIX 2 breadcrumb added to _record_dispatch()'s prompt-redaction
block (the parallel site to cast_subagent_stop.py's _redact_fail_closed): on a
forced redaction failure, the ~/.claude/logs/hook-errors.log line must contain
the input byte length and the failing exception's class name (or "none" when
the redact subprocess failed without raising), and must NEVER contain any
fragment of the input prompt.

HOME is redirected to an isolated temp dir for every test in this file (the
Python-test analogue of the BATS setup_temp_home/teardown_temp_home HARD RULE)
so hook-errors.log is never written under the real ~/.claude. CAST_DB_PATH
points at a nonexistent file so _record_dispatch no-ops (returns) right after
the redaction block under test — this file covers the breadcrumb in isolation,
not the dispatch_decisions INSERT itself.
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_SCRIPT_PATH = _SCRIPTS_DIR / 'cast-pretool-dispatch.py'

# Hyphenated filename cannot be imported normally — load via importlib, same
# pattern as tests/test_cast_audit.py.
_spec = importlib.util.spec_from_file_location('cast_pretool_dispatch', str(_SCRIPT_PATH))
cast_pretool_dispatch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cast_pretool_dispatch)


class _IsolatedHomeTestCase(unittest.TestCase):
    """Redirects HOME to an isolated temp dir so _log_error's hardcoded
    ~/.claude/logs/hook-errors.log target never touches the real home
    directory, and points CAST_DB_PATH at a nonexistent file so
    _record_dispatch no-ops after the redaction block under test."""

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._orig_db_path = os.environ.get('CAST_DB_PATH')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-pretool-dispatch-test-')
        os.environ['HOME'] = self._tmpdir
        os.environ['CAST_DB_PATH'] = os.path.join(self._tmpdir, 'nonexistent-cast.db')

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        if self._orig_db_path is None:
            os.environ.pop('CAST_DB_PATH', None)
        else:
            os.environ['CAST_DB_PATH'] = self._orig_db_path
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _read_log(self) -> str:
        log_path = os.path.join(self._tmpdir, '.claude', 'logs', 'hook-errors.log')
        if not os.path.isfile(log_path):
            return ''
        with open(log_path) as f:
            return f.read()


class TestDispatchRedactionBreadcrumb(_IsolatedHomeTestCase):

    @staticmethod
    def _data(prompt: str) -> dict:
        return {
            'tool_input': {'subagent_type': 'test-agent', 'prompt': prompt},
            'session_id': 'test-session',
        }

    def test_forced_exception_logs_byte_length_and_exception_class(self):
        secret_prompt = 'SECRET_MARKER_should_never_appear_in_the_log_67890'
        with mock.patch('subprocess.run', side_effect=TimeoutError('boom')):
            cast_pretool_dispatch._record_dispatch(self._data(secret_prompt))

        log_content = self._read_log()
        self.assertIn('site=dispatch_decisions.prompt', log_content)
        self.assertIn(f'input_bytes={len(secret_prompt.encode("utf-8"))}', log_content)
        self.assertIn('exception=TimeoutError', log_content)

    def test_breadcrumb_never_contains_input_content(self):
        secret_prompt = 'SECRET_MARKER_should_never_appear_in_the_log_67890'
        with mock.patch('subprocess.run', side_effect=TimeoutError('boom')):
            cast_pretool_dispatch._record_dispatch(self._data(secret_prompt))

        log_content = self._read_log()
        self.assertNotIn('SECRET_MARKER', log_content)
        self.assertNotIn(secret_prompt, log_content)

    def test_nonzero_returncode_without_exception_logs_exception_none(self):
        """The redact subprocess can fail WITHOUT raising (nonzero exit, empty
        stdout) — the breadcrumb must say so honestly rather than fabricating
        a class name."""
        fake_result = mock.Mock(returncode=1, stdout='')
        with mock.patch('subprocess.run', return_value=fake_result):
            cast_pretool_dispatch._record_dispatch(self._data('some prompt'))

        self.assertIn('exception=none', self._read_log())

    def test_successful_redaction_does_not_log(self):
        fake_result = mock.Mock(returncode=0, stdout='redacted prompt\n')
        with mock.patch('subprocess.run', return_value=fake_result):
            cast_pretool_dispatch._record_dispatch(self._data('some prompt'))

        self.assertEqual(self._read_log(), '')

    def test_empty_prompt_skips_redaction_and_log(self):
        with mock.patch('subprocess.run') as mocked_run:
            cast_pretool_dispatch._record_dispatch(self._data(''))

        mocked_run.assert_not_called()
        self.assertEqual(self._read_log(), '')


if __name__ == '__main__':
    unittest.main()
