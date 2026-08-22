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
import sqlite3
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


class TestDispatchDecisionsNameCapture(unittest.TestCase):
    """Covers the dispatch_name capture (I-2c): _record_dispatch() must persist a
    dispatch's custom Agent-tool `name=` alongside chosen_agent (the roster type),
    so a later fix can join on whichever value SubagentStop actually saw as
    ctx.agent_name — see scripts/migrations/033_dispatch_decisions_name.sql for the
    full mechanism this guards against regressing.

    Unlike TestDispatchRedactionBreadcrumb above, CAST_DB_PATH here points at a REAL
    temp sqlite DB (not a nonexistent file) so the INSERT path under test actually
    runs. HOME and CAST_DB_PATH are both saved/restored via a `finally` in tearDown
    per the isolation HARD RULE — never touch the real ~/.claude/cast.db."""

    def setUp(self):
        self._orig_home = os.environ.get('HOME')
        self._orig_db_path = os.environ.get('CAST_DB_PATH')
        self._tmpdir = tempfile.mkdtemp(prefix='cast-pretool-dispatch-name-test-')
        os.environ['HOME'] = self._tmpdir
        self._db_path = os.path.join(self._tmpdir, 'test-cast.db')
        os.environ['CAST_DB_PATH'] = self._db_path

    def tearDown(self):
        try:
            if self._orig_home is None:
                os.environ.pop('HOME', None)
            else:
                os.environ['HOME'] = self._orig_home
            if self._orig_db_path is None:
                os.environ.pop('CAST_DB_PATH', None)
            else:
                os.environ['CAST_DB_PATH'] = self._orig_db_path
        finally:
            shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _make_db(self, with_dispatch_name: bool) -> None:
        """Create a fresh dispatch_decisions table at self._db_path — either the
        post-migration-033 shape (dispatch_name column present) or the legacy
        pre-migration shape, to exercise the unmigrated-DB fallback path."""
        cols = (
            "id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, "
            "prompt_snippet TEXT, chosen_agent TEXT, model TEXT, "
            "created_at TEXT DEFAULT (datetime('now')), outcome TEXT DEFAULT 'pending'"
        )
        if with_dispatch_name:
            cols += ", dispatch_name TEXT"
        conn = sqlite3.connect(self._db_path)
        try:
            conn.execute(f"CREATE TABLE dispatch_decisions ({cols})")
            conn.commit()
        finally:
            conn.close()

    @staticmethod
    def _data(subagent_type: str, name=None) -> dict:
        ti = {'subagent_type': subagent_type, 'prompt': ''}
        if name is not None:
            ti['name'] = name
        return {'tool_input': ti, 'session_id': 'test-session'}

    def _row(self):
        conn = sqlite3.connect(self._db_path)
        try:
            return conn.execute(
                "SELECT chosen_agent, dispatch_name FROM dispatch_decisions"
            ).fetchone()
        finally:
            conn.close()

    def test_name_set_records_both_dispatch_name_and_chosen_agent(self):
        self._make_db(with_dispatch_name=True)
        cast_pretool_dispatch._record_dispatch(
            self._data('code-reviewer', name='code-reviewer__unit-a')
        )
        row = self._row()
        self.assertIsNotNone(row)
        chosen_agent, dispatch_name = row
        self.assertEqual(chosen_agent, 'code-reviewer')
        self.assertEqual(dispatch_name, 'code-reviewer__unit-a')
        self.assertNotEqual(chosen_agent, dispatch_name)

    def test_no_name_key_records_null_dispatch_name(self):
        self._make_db(with_dispatch_name=True)
        cast_pretool_dispatch._record_dispatch(self._data('code-reviewer'))
        row = self._row()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 'code-reviewer')
        self.assertIsNone(row[1])

    def test_unmigrated_db_falls_back_and_still_records_row(self):
        """Regression guard: an INSERT against a pre-migration-033 DB (no
        dispatch_name column) must fall back to the original 5-column INSERT
        rather than let the OperationalError propagate to the outer `except
        Exception`, which would silently stop recording the row entirely."""
        self._make_db(with_dispatch_name=False)
        conn = sqlite3.connect(self._db_path)
        try:
            before = conn.execute("SELECT COUNT(*) FROM dispatch_decisions").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(before, 0)

        cast_pretool_dispatch._record_dispatch(
            self._data('code-reviewer', name='code-reviewer__unit-a')
        )

        conn = sqlite3.connect(self._db_path)
        try:
            after = conn.execute("SELECT COUNT(*) FROM dispatch_decisions").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(after, 1)

    def test_non_string_name_stores_null_without_raising(self):
        self._make_db(with_dispatch_name=True)
        data = self._data('code-reviewer')
        data['tool_input']['name'] = 123
        cast_pretool_dispatch._record_dispatch(data)  # must not raise
        row = self._row()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 'code-reviewer')
        self.assertIsNone(row[1])

    # ── I-2c hardening: shape gate + redaction screen + fail-closed ─────────

    def test_benign_roster_name_survives_unredacted(self):
        """Regression guard: the hardening pipeline must not mangle a normal
        roster-style dispatch name — attribution must still resolve for the
        overwhelming majority of real dispatches."""
        self._make_db(with_dispatch_name=True)
        cast_pretool_dispatch._record_dispatch(
            self._data('backend-writer', name='backend-writer__i2c-producer')
        )
        row = self._row()
        self.assertIsNotNone(row)
        self.assertEqual(row[1], 'backend-writer__i2c-producer')

    def test_token_shaped_name_is_redacted_not_stored_raw(self):
        """A name that satisfies Claude Code's charset but is shaped like a real
        secret (AWS access key ID) must be redacted, not stored verbatim."""
        self._make_db(with_dispatch_name=True)
        raw = 'AKIAQQQQZZZZWWWWRRRR'
        cast_pretool_dispatch._record_dispatch(self._data('backend-writer', name=raw))
        row = self._row()
        self.assertIsNotNone(row)
        stored = row[1]
        self.assertIsNotNone(stored)
        self.assertNotIn(raw, stored)
        self.assertNotEqual(stored, raw)

    def test_name_with_embedded_newline_stores_null(self):
        """A newline fails the ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ shape gate outright
        — the control-character closure the earlier review round flagged as
        missing (fullmatch, not match+trailing $, is what makes this reject)."""
        self._make_db(with_dispatch_name=True)
        cast_pretool_dispatch._record_dispatch(
            self._data('backend-writer', name='backend-writer__unit\n')
        )
        row = self._row()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 'backend-writer')
        self.assertIsNone(row[1])

    def test_overlong_name_stores_null(self):
        """A name past the 64-char bound (^...{0,63} after the first char) fails
        the shape gate rather than being silently truncated."""
        self._make_db(with_dispatch_name=True)
        overlong = 'a' * 65
        cast_pretool_dispatch._record_dispatch(
            self._data('backend-writer', name=overlong)
        )
        row = self._row()
        self.assertIsNotNone(row)
        self.assertIsNone(row[1])

    def test_redactor_unavailable_fails_closed_not_open(self):
        """If the redactor module can't load, dispatch_name must store None —
        never the raw name. This is the one that proves fail-CLOSED rather than
        fail-open: a fail-open bug here would leak whatever the shape gate lets
        through whenever cast-redact.py is broken or missing."""
        self._make_db(with_dispatch_name=True)
        raw = 'backend-writer__would-otherwise-be-stored'
        with mock.patch.object(cast_pretool_dispatch, '_load', return_value=None):
            cast_pretool_dispatch._record_dispatch(self._data('backend-writer', name=raw))
        row = self._row()
        self.assertIsNotNone(row)
        self.assertIsNone(row[1])
        # Assert the raw value truly never reached the DB (not merely "!= None").
        conn = sqlite3.connect(self._db_path)
        try:
            all_names = [r[0] for r in conn.execute(
                "SELECT dispatch_name FROM dispatch_decisions").fetchall()]
        finally:
            conn.close()
        self.assertNotIn(raw, all_names)


if __name__ == '__main__':
    unittest.main()
