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
import contextlib
import gc
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
import warnings
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
        # Split literal, deliberately: the assembled value is still AKIA-shaped so
        # the redaction screen sees a genuine AWS-key pattern, but no tracked LINE
        # matches ci-pii-scan.sh's AKIA[0-9A-Z]{16} regex. Same remedy already used
        # for this repo's other secret-shaped fixtures (2902a2b, 61b8d03).
        # Do NOT rejoin this into one literal, and do NOT allowlist this file in
        # .gitleaks.toml instead — an allowlist would blind both scanners to a REAL
        # secret committed here later.
        raw = 'AKIA' + 'QQQQZZZZWWWWRRRR'
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


_LINT_MOD_NAME = 'cast_lint_workflow_stage_models'
_LINT_FILENAME = 'cast-lint-workflow-stage-models.py'

_WF_BAD = "const r = await agent(PROMPT, { label: 'scan' })\n"
_WF_OK = "const r = await agent(PROMPT, { label: 'scan', model: 'haiku' })\n"

# Subprocess snippets: each probes a failure that would KILL or HANG the process,
# so it must run out-of-process (a regression then fails a test instead of
# taking down / freezing the suite). argv[1] = path of the dispatcher script.

# A SIGALRM delivered AFTER the watchdog helper has returned (or timed out). If
# the helper left SIG_DFL installed, the default action terminates the process
# (exit 142 / -14): a crashed hook, which Claude Code treats as a BLOCK.
_PENDING_ALARM_SNIPPET = r'''
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("d", sys.argv[1])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
lint = d._load("cast_lint_workflow_stage_models", "cast-lint-workflow-stage-models.py")
if sys.argv[2] == "timeout":
    d._WORKFLOW_LINT_BUDGET_SECS = 0.05
    src = ("agent(" * 150).ljust(64 * 1024, " ")
else:
    src = "agent(P);\n"
try:
    results = d._lint_with_watchdog(lint, [src])
    outcome = "ok:%d" % len(results[0][0])
except d._WorkflowLintTimeout:
    outcome = "timeout"
os.kill(os.getpid(), signal.SIGALRM)   # pending alarm arriving after the helper
for _ in range(200000):
    pass                               # let the interpreter dispatch it
print(outcome)
'''

# stat() says "regular file" but the path is a FIFO when open() runs (the
# stat-then-open race, simulated by making every os.stat lie). A plain open()
# of a FIFO with no writer blocks forever; the fd-based read must not.
_TOCTOU_SNIPPET = r'''
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("d", sys.argv[1])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
regular = os.stat(sys.argv[1])
os.stat = lambda *a, **k: regular
print(repr(d._workflow_sources({}, {"scriptPath": sys.argv[2]})))
'''


class TestWorkflowStageModelGuard(_IsolatedHomeTestCase):
    """PreToolUse deny for a Workflow script whose agent() stage has no model:.

    Stages without model: silently inherit the opus main-loop model (cost lever,
    Ed-approved 2026-10-03; mode = DENY with reason). The path must be
    exception-proof: Claude Code >= 2.1.288 BLOCKS a tool call when a PreToolUse
    hook crashes or prints malformed output, so every failure mode here must
    ALLOW silently (nothing on stdout, exit 0) and be logged.

    Each in-process test drives main() with a patched stdin and captured stdout;
    two end-to-end tests spawn the real script. _record_guard_failure is mocked
    so no marker file / cast.db row is ever written.
    """

    def setUp(self):
        super().setUp()
        self._env_patch = mock.patch.dict(os.environ)
        self._env_patch.start()
        os.environ.pop('CLAUDE_SUBPROCESS', None)
        cast_pretool_dispatch._MODULE_CACHE.pop(_LINT_MOD_NAME, None)
        self._rec = mock.patch.object(cast_pretool_dispatch, '_record_guard_failure')
        self.record_failure = self._rec.start()

    def tearDown(self):
        self._rec.stop()
        cast_pretool_dispatch._MODULE_CACHE.pop(_LINT_MOD_NAME, None)
        self._env_patch.stop()
        super().tearDown()

    # -- helpers ---------------------------------------------------------
    def _run(self, payload):
        raw = json.dumps(payload).encode('utf-8')
        stdin = io.TextIOWrapper(io.BytesIO(raw), encoding='utf-8')
        out = io.StringIO()
        with mock.patch.object(sys, 'stdin', stdin), contextlib.redirect_stdout(out):
            rc = cast_pretool_dispatch.main()
        return rc, out.getvalue()

    def _wf(self, **tool_input):
        return {'tool_name': 'Workflow', 'tool_input': tool_input,
                'session_id': 'test-session'}

    def _assert_allow(self, payload):
        rc, out = self._run(payload)
        self.assertEqual(rc, 0)
        self.assertEqual(out, '')

    def _assert_deny(self, payload):
        """Exit 0 + EXACTLY ONE well-formed deny object on stdout; return reason."""
        rc, out = self._run(payload)
        self.assertEqual(rc, 0)
        obj, end = json.JSONDecoder().raw_decode(out.strip())
        self.assertEqual(end, len(out.strip()), 'stdout holds more than one JSON object')
        self.assertEqual(list(obj), ['hookSpecificOutput'])
        hso = obj['hookSpecificOutput']
        self.assertEqual(hso['hookEventName'], 'PreToolUse')
        self.assertEqual(hso['permissionDecision'], 'deny')
        self.assertIsInstance(hso['permissionDecisionReason'], str)
        return hso['permissionDecisionReason']

    def _write(self, name, text):
        path = os.path.join(self._tmpdir, name)
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(text)
        return path

    # -- inline script ---------------------------------------------------
    def test_inline_missing_model_denies_with_actionable_reason(self):
        reason = self._assert_deny(self._wf(script="// header\n" + _WF_BAD))
        self.assertIn('line 2', reason)
        self.assertIn('agent(PROMPT', reason)
        for tier in ("'haiku'", "'sonnet'", "'opus'"):
            self.assertIn(tier, reason)
        self.assertIn('cast-lint: inherit-model --', reason)

    def test_all_stages_pinned_allows_silently(self):
        self._assert_allow(self._wf(script=_WF_OK + _WF_OK))

    def test_script_with_no_agent_calls_allows(self):
        self._assert_allow(self._wf(script="const x = 1 + 1\nreturn x\n"))

    def test_opt_out_with_reason_allows(self):
        src = ("// cast-lint: inherit-model -- final judge, needs session opus\n"
               + _WF_BAD)
        self._assert_allow(self._wf(script=src))

    def test_bare_opt_out_marker_still_denies(self):
        src = "// cast-lint: inherit-model --\n" + _WF_BAD
        self._assert_deny(self._wf(script=src))

    def test_model_only_in_comment_or_string_still_denies(self):
        src = ("// model: 'haiku'\n"
               "const r = await agent('use model: haiku here', { label: 'x' })\n")
        reason = self._assert_deny(self._wf(script=src))
        self.assertIn('line 2', reason)

    def test_nested_inner_model_does_not_satisfy_outer(self):
        src = ("const r = await agent('outer ' + (await agent(P, { model: 'haiku' })),\n"
               "                      { label: 'outer' })\n")
        reason = self._assert_deny(self._wf(script=src))
        self.assertIn('line 1', reason)
        self.assertIn('1 agent()', reason)

    def test_reason_lists_at_most_ten_entries_and_stays_bounded(self):
        pad = 'x' * 200
        src = ''.join(
            "const r%d = await agent(PROMPT_%s, { label: 'l%d' })\n" % (i, pad, i)
            for i in range(14))
        reason = self._assert_deny(self._wf(script=src))
        entries = [ln for ln in reason.splitlines() if re.match(r'line \d+: ', ln)]
        self.assertEqual(len(entries), 10)
        self.assertIn('14', reason)
        self.assertLessEqual(len(reason), 1500)
        for ln in entries:  # each snippet is trimmed to <= 80 chars
            self.assertLessEqual(len(ln.split(': ', 1)[1]), 80)

    # -- scriptPath ------------------------------------------------------
    def test_scriptpath_with_violation_denies(self):
        path = self._write('bad.workflow.js', "\n\n" + _WF_BAD)
        reason = self._assert_deny(self._wf(scriptPath=path))
        self.assertIn('line 3', reason)

    def test_scriptpath_clean_allows(self):
        self._assert_allow(self._wf(scriptPath=self._write('ok.workflow.js', _WF_OK)))

    def test_scriptpath_relative_resolves_against_payload_cwd(self):
        self._write('rel.workflow.js', _WF_BAD)
        payload = self._wf(scriptPath='rel.workflow.js')
        payload['cwd'] = self._tmpdir
        self._assert_deny(payload)

    def test_scriptpath_missing_allows(self):
        self._assert_allow(self._wf(scriptPath=os.path.join(self._tmpdir, 'nope.js')))

    def test_scriptpath_directory_allows(self):
        self._assert_allow(self._wf(scriptPath=self._tmpdir))

    def test_scriptpath_over_one_mib_allows(self):
        path = self._write('big.workflow.js', _WF_BAD + ' ' * (1024 * 1024 + 16))
        self._assert_allow(self._wf(scriptPath=path))

    def test_scriptpath_not_a_string_allows(self):
        self._assert_allow(self._wf(scriptPath=['a', 'b']))

    def test_script_and_scriptpath_are_both_linted(self):
        bad = self._write('bad.workflow.js', _WF_BAD)
        ok = self._write('ok.workflow.js', _WF_OK)
        self._assert_deny(self._wf(script=_WF_OK, scriptPath=bad))   # path violates
        self._assert_deny(self._wf(script=_WF_BAD, scriptPath=ok))   # script violates
        self._assert_allow(self._wf(script=_WF_OK, scriptPath=ok))

    def test_both_sources_violating_are_labelled_in_the_reason(self):
        bad = self._write('bad.workflow.js', "\n" + _WF_BAD)
        reason = self._assert_deny(self._wf(script=_WF_BAD, scriptPath=bad))
        self.assertIn('2 agent() stage(s)', reason)
        self.assertIn('script line 1:', reason)
        self.assertIn('scriptPath line 2:', reason)

    def test_single_source_reason_keeps_bare_line_prefix(self):
        reason = self._assert_deny(self._wf(script=_WF_BAD))
        self.assertTrue(re.search(r'^line 1: ', reason, re.M))
        self.assertNotIn('script line', reason)

    def test_empty_script_does_not_shadow_a_real_scriptpath(self):
        bad = self._write('bad.workflow.js', _WF_BAD)
        self._assert_deny(self._wf(script='', scriptPath=bad))

    def test_empty_script_alone_allows(self):
        self._assert_allow(self._wf(script=''))

    def test_non_string_script_falls_through_to_scriptpath(self):
        bad = self._write('bad.workflow.js', _WF_BAD)
        self._assert_deny(self._wf(script=123, scriptPath=bad))

    # -- other input forms / anomalies -> allow --------------------------
    def test_name_only_allows(self):
        self._assert_allow(self._wf(name='some-saved-workflow'))

    def test_empty_tool_input_allows(self):
        self._assert_allow(self._wf())

    def test_script_not_a_string_allows(self):
        for bad in (123, None, ['agent(P)'], {'a': 1}):
            with self.subTest(script=bad):
                self._assert_allow(self._wf(script=bad))

    def test_unterminated_quote_allows_and_logs(self):
        self._assert_allow(self._wf(script="const s = await agent(P, { label: 'oops })\n"))
        self.assertIn('unterminated', self._read_log())

    def test_lint_module_load_failure_allows_silently(self):
        with mock.patch.object(cast_pretool_dispatch, '_load', return_value=None):
            self._assert_allow(self._wf(script=_WF_BAD))

    def test_lint_module_missing_file_allows_and_records_failure(self):
        with mock.patch.object(cast_pretool_dispatch, 'SCRIPT_DIR', self._tmpdir):
            self._assert_allow(self._wf(script=_WF_BAD))
        self.assertIn('failed to load', self._read_log())
        self.record_failure.assert_called()

    def test_lint_exception_allows_logs_and_records_failure(self):
        lint = cast_pretool_dispatch._load(_LINT_MOD_NAME, _LINT_FILENAME)
        self.assertIsNotNone(lint)
        with mock.patch.object(lint, 'find_violations_in_source',
                               side_effect=RuntimeError('boom')):
            self._assert_allow(self._wf(script=_WF_BAD))
        self.assertIn('RuntimeError', self._read_log())
        self.record_failure.assert_called()

    # -- fail-open size / call-count bounds (hook-only; the CLI has none) ---
    # The hook has a 5 s timeout and the lint is superlinear on pathological
    # input, so oversize or call-heavy sources are ALLOWED unlinted + logged.
    def _pad_to(self, src, n_chars):
        return src + ' ' * (n_chars - len(src))

    def test_source_at_256_kib_bound_is_still_linted(self):
        src = self._pad_to(_WF_BAD, 256 * 1024)
        self.assertEqual(len(src), 256 * 1024)
        self._assert_deny(self._wf(script=src))

    def test_source_over_256_kib_allows_unlinted_and_logs(self):
        src = self._pad_to(_WF_BAD, 256 * 1024 + 1)
        lint = cast_pretool_dispatch._load(_LINT_MOD_NAME, _LINT_FILENAME)
        with mock.patch.object(lint, 'find_violations_in_source') as mocked:
            self._assert_allow(self._wf(script=src))
        mocked.assert_not_called()
        log = self._read_log()
        self.assertIn('workflow stage-model lint skipped', log)
        self.assertIn('bound', log)
        self.assertEqual(len([ln for ln in log.splitlines() if 'skipped' in ln]), 1)

    def test_scriptpath_over_256_kib_but_under_1_mib_allows_unlinted(self):
        path = self._write('mid.workflow.js',
                           self._pad_to(_WF_BAD, 256 * 1024 + 1))
        self._assert_allow(self._wf(scriptPath=path))
        self.assertIn('workflow stage-model lint skipped', self._read_log())

    def test_exactly_2000_agent_calls_are_still_linted(self):
        src = "agent(P);\n" * 2000
        reason = self._assert_deny(self._wf(script=src))
        self.assertIn('2000 agent() stage(s)', reason)

    def test_over_2000_agent_calls_allows_unlinted_and_logs(self):
        src = "agent(P);\n" * 2001
        lint = cast_pretool_dispatch._load(_LINT_MOD_NAME, _LINT_FILENAME)
        with mock.patch.object(lint, 'find_violations_in_source') as mocked:
            self._assert_allow(self._wf(script=src))
        mocked.assert_not_called()
        log = self._read_log()
        self.assertIn('workflow stage-model lint skipped', log)
        self.assertIn('bound', log)
        self.assertEqual(len([ln for ln in log.splitlines() if 'skipped' in ln]), 1)

    def test_bound_logs_never_contain_script_text(self):
        marker = 'SECRET_SCRIPT_MARKER_55'
        src = ("// %s\n" % marker) + "agent(P);\n" * 2001
        self._assert_allow(self._wf(script=src))
        self.assertNotIn(marker, self._read_log())

    # -- wall-clock watchdog (SIGALRM, 2 s) ----------------------------------
    # The size / count bounds do not cap run time on MALFORMED nesting: 150
    # unclosed agent( + 64 KiB of padding takes ~10 s unmitigated (measured),
    # against the hook's 5 s timeout. The watchdog ALLOWS + logs on expiry.
    @staticmethod
    def _slow_malformed(pad_to=64 * 1024):
        return ("agent(" * 150).ljust(pad_to, " ")

    def _arm_probe(self):
        """Install a sentinel SIGALRM handler (restored on cleanup) so a test can
        prove the guard put it back; returns the sentinel."""
        def sentinel(signum, frame):
            pass
        prev = signal.signal(signal.SIGALRM, sentinel)
        self.addCleanup(signal.signal, signal.SIGALRM, prev)
        return sentinel

    def _assert_timer_clean(self, sentinel):
        self.assertIs(signal.getsignal(signal.SIGALRM), sentinel)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))

    def _timeout_log_lines(self):
        return [ln for ln in self._read_log().splitlines() if 'timed out' in ln]

    def test_pathological_input_times_out_allows_within_3s(self):
        sentinel = self._arm_probe()
        t0 = time.monotonic()
        self._assert_allow(self._wf(script=self._slow_malformed()))
        elapsed = time.monotonic() - t0
        self.assertLess(elapsed, 3.0, 'watchdog did not cut the lint off')
        lines = self._timeout_log_lines()
        self.assertEqual(len(lines), 1)
        self.assertIn('workflow stage-model lint', lines[0])
        self.assertIn(str(64 * 1024), lines[0])  # source size, in chars
        self.assertIn('150', lines[0])           # agent( matches
        self._assert_timer_clean(sentinel)

    def test_timeout_log_line_is_content_free(self):
        marker = 'SECRET_SCRIPT_MARKER_77'
        src = ('// %s\n' % marker) + self._slow_malformed()
        with mock.patch.object(cast_pretool_dispatch, '_WORKFLOW_LINT_BUDGET_SECS', 0.05):
            self._assert_allow(self._wf(script=src))
        self.assertEqual(len(self._timeout_log_lines()), 1)
        self.assertNotIn(marker, self._read_log())

    def test_timer_and_handler_restored_after_timeout_path(self):
        sentinel = self._arm_probe()
        with mock.patch.object(cast_pretool_dispatch, '_WORKFLOW_LINT_BUDGET_SECS', 0.05):
            self._assert_allow(self._wf(script=self._slow_malformed()))
        self.assertEqual(len(self._timeout_log_lines()), 1)
        self._assert_timer_clean(sentinel)

    def test_timer_and_handler_restored_after_normal_paths(self):
        sentinel = self._arm_probe()
        self._assert_deny(self._wf(script=_WF_BAD))
        self._assert_timer_clean(sentinel)
        self._assert_allow(self._wf(script=_WF_OK))
        self._assert_timer_clean(sentinel)
        self.assertEqual(self._timeout_log_lines(), [])

    def test_timer_and_handler_restored_after_lint_exception(self):
        sentinel = self._arm_probe()
        lint = cast_pretool_dispatch._load(_LINT_MOD_NAME, _LINT_FILENAME)
        with mock.patch.object(lint, 'find_violations_in_source',
                               side_effect=RuntimeError('boom')):
            self._assert_allow(self._wf(script=_WF_BAD))
        self._assert_timer_clean(sentinel)

    def test_watchdog_budget_is_two_seconds_and_cancelled(self):
        with mock.patch.object(signal, 'setitimer', wraps=signal.setitimer) as spy:
            self._assert_deny(self._wf(script=_WF_BAD))
        self.assertEqual(spy.call_args_list[0], mock.call(signal.ITIMER_REAL, 2.0))
        self.assertEqual(spy.call_args_list[-1], mock.call(signal.ITIMER_REAL, 0))

    def test_runs_without_watchdog_when_setitimer_or_sigalrm_missing(self):
        for attr in ('setitimer', 'SIGALRM'):
            with self.subTest(missing=attr):
                orig = getattr(signal, attr)
                delattr(signal, attr)
                try:
                    self._assert_deny(self._wf(script=_WF_BAD))
                    self._assert_allow(self._wf(script=_WF_OK))
                finally:
                    setattr(signal, attr, orig)

    def test_non_main_thread_skips_watchdog_and_still_lints(self):
        sentinel = self._arm_probe()
        box = {}

        def work():
            try:
                box['deny'] = self._run(self._wf(script=_WF_BAD))
                box['allow'] = self._run(self._wf(script=_WF_OK))
            except BaseException as exc:  # surfaced via the assertion below
                box['err'] = exc

        th = threading.Thread(target=work)
        th.start()
        th.join(30)
        self.assertFalse(th.is_alive())
        self.assertNotIn('err', box)
        rc, out = box['deny']
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertEqual(box['allow'], (0, ''))
        self._assert_timer_clean(sentinel)

    def test_alarm_landing_right_after_handler_install_still_restores(self):
        # A stale in-flight alarm can raise the instant signal.signal() returns --
        # before `previous` is bound. The install is inside the try (sentinel for
        # `previous`), so the finally still replaces the leaked _on_alarm handler
        # with a no-op, the timer is never left armed, and fn never runs.
        real_signal = signal.signal
        installed = []

        def racing_signal(signum, handler):
            prev = real_signal(signum, handler)
            if signum == signal.SIGALRM and getattr(handler, '__name__', '') == '_on_alarm':
                installed.append(handler)
                raise cast_pretool_dispatch._WorkflowLintTimeout()
            return prev
        sentinel = self._arm_probe()
        ran = []
        with mock.patch.object(signal, 'signal', side_effect=racing_signal):
            with self.assertRaises(cast_pretool_dispatch._WorkflowLintTimeout):
                cast_pretool_dispatch._run_under_watchdog(lambda: ran.append(1), 5.0)
        self.assertEqual((len(installed), ran), (1, []))
        handler = signal.getsignal(signal.SIGALRM)
        self.assertIsNot(handler, installed[0], 'leaked the alarm handler')
        self.assertTrue(callable(handler))
        self.assertEqual(handler.__name__, '_noop')
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))
        del sentinel

    def test_alarm_in_flight_at_cancel_is_a_noop_and_result_survives(self):
        # The "armed flag" race: an alarm already in flight when setitimer(0) cancels the
        # timer must NOT raise once fn has finished. Delivered here, deterministically, by
        # signalling ourselves from inside the cancel call. Without the flag _on_alarm
        # raises _WorkflowLintTimeout out of the finally and fn's result is lost.
        real_setitimer = signal.setitimer
        delivered = []

        def setitimer_with_inflight_alarm(which, seconds, *rest):
            old = real_setitimer(which, seconds, *rest)
            if seconds == 0:
                delivered.append(1)
                os.kill(os.getpid(), signal.SIGALRM)
            return old
        self.addCleanup(real_setitimer, signal.ITIMER_REAL, 0)  # never poison later tests
        sentinel = self._arm_probe()
        with mock.patch.object(signal, 'setitimer', side_effect=setitimer_with_inflight_alarm):
            result = cast_pretool_dispatch._run_under_watchdog(lambda: 'fn-result', 5.0)
        self.assertEqual((result, delivered), ('fn-result', [1]))
        self._assert_timer_clean(sentinel)

    def test_alarm_after_watchdog_returns_is_harmless_and_handler_not_leaked(self):
        prev = signal.signal(signal.SIGALRM, signal.SIG_DFL)
        self.addCleanup(signal.signal, signal.SIGALRM, prev)
        self.assertEqual(cast_pretool_dispatch._run_under_watchdog(lambda: 7, 5.0), 7)
        os.kill(os.getpid(), signal.SIGALRM)  # must not raise, must not kill us
        handler = signal.getsignal(signal.SIGALRM)
        self.assertTrue(callable(handler))
        self.assertNotEqual(handler.__name__, '_on_alarm', 'leaked the raising handler')
        handler(signal.SIGALRM, None)  # whatever is installed must not raise
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))

    def test_watchdog_armed_only_around_the_lint_itself(self):
        # Not for other tools, and not for any Workflow input that short-circuits
        # before linting (name-only, over either bound).
        too_big = _WF_BAD + ' ' * (256 * 1024 + 1)
        cases = [
            {'tool_name': 'Agent', 'tool_input': {'subagent_type': 'x'}},
            {'tool_name': 'Glob', 'tool_input': {}},
            self._wf(name='saved-workflow'),
            self._wf(scriptPath=['a', 'b']),  # not a str -> no read, no window
            self._wf(scriptPath=''),
            self._wf(script=too_big),
            self._wf(script="agent(P);\n" * 2001),
        ]
        with mock.patch.object(signal, 'setitimer') as setitimer, \
                mock.patch.object(signal, 'signal') as sig:
            for payload in cases:
                with self.subTest(case=payload['tool_name'] + str(list(payload['tool_input']))):
                    rc, out = self._run(payload)
                    self.assertEqual((rc, out), (0, ''))
        setitimer.assert_not_called()
        sig.assert_not_called()

    def test_e2e_pathological_input_allows_within_budget(self):
        t0 = time.monotonic()
        proc = self._spawn(self._wf(script=self._slow_malformed()))
        elapsed = time.monotonic() - t0
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b'')
        self.assertLess(elapsed, 3.5, 'real script was not cut off by the watchdog')

    # -- SIGALRM disposition after the watchdog (Low-1) -----------------------
    # A single-shot hook process must never be left with SIG_DFL on SIGALRM: a
    # late alarm would then terminate it (exit 142) -> crashed hook -> BLOCK.
    def test_sig_dfl_is_replaced_by_a_noop_not_restored(self):
        prev = signal.signal(signal.SIGALRM, signal.SIG_DFL)
        self.addCleanup(signal.signal, signal.SIGALRM, prev)
        self._assert_deny(self._wf(script=_WF_BAD))
        self.assertTrue(callable(signal.getsignal(signal.SIGALRM)),
                        'SIG_DFL was left installed after the watchdog')
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))

    def test_sig_dfl_is_replaced_by_a_noop_after_timeout_too(self):
        prev = signal.signal(signal.SIGALRM, signal.SIG_DFL)
        self.addCleanup(signal.signal, signal.SIGALRM, prev)
        with mock.patch.object(cast_pretool_dispatch, '_WORKFLOW_LINT_BUDGET_SECS', 0.05):
            self._assert_allow(self._wf(script=self._slow_malformed()))
        self.assertEqual(len(self._timeout_log_lines()), 1)
        self.assertTrue(callable(signal.getsignal(signal.SIGALRM)))
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))

    def test_previous_sig_ign_is_restored(self):
        prev = signal.signal(signal.SIGALRM, signal.SIG_IGN)
        self.addCleanup(signal.signal, signal.SIGALRM, prev)
        self._assert_deny(self._wf(script=_WF_BAD))
        self.assertEqual(signal.getsignal(signal.SIGALRM), signal.SIG_IGN)

    def test_pending_alarm_after_helper_returns_does_not_kill_the_process(self):
        proc = self._spawn_snippet(_PENDING_ALARM_SNIPPET, 'normal', timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode('utf-8', 'replace'))
        self.assertEqual(proc.stdout.decode().strip(), 'ok:1')

    def test_pending_alarm_after_timeout_does_not_kill_the_process(self):
        proc = self._spawn_snippet(_PENDING_ALARM_SNIPPET, 'timeout', timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode('utf-8', 'replace'))
        self.assertEqual(proc.stdout.decode().strip(), 'timeout')

    # -- scriptPath read hardening (Low-2 + Info) -----------------------------
    def test_fifo_scriptpath_allows_quickly(self):
        fifo = os.path.join(self._tmpdir, 'pipe.workflow.js')
        os.mkfifo(fifo)
        t0 = time.monotonic()
        proc = self._spawn(self._wf(scriptPath=fifo), timeout=20)
        self.assertEqual((proc.returncode, proc.stdout), (0, b''))
        self.assertLess(time.monotonic() - t0, 10.0)

    def test_fifo_with_a_violating_script_in_it_is_never_read(self):
        fifo = os.path.join(self._tmpdir, 'pipe.workflow.js')
        os.mkfifo(fifo)
        wfd = os.open(fifo, os.O_RDWR)  # keeps a writer alive; data is readable
        self.addCleanup(os.close, wfd)
        os.write(wfd, _WF_BAD.encode('utf-8'))
        proc = self._spawn(self._wf(scriptPath=fifo), timeout=20)
        self.assertEqual((proc.returncode, proc.stdout), (0, b''))

    def test_stat_then_open_swap_to_a_fifo_cannot_hang_the_hook(self):
        fifo = os.path.join(self._tmpdir, 'swapped.workflow.js')
        os.mkfifo(fifo)
        proc = self._spawn_snippet(_TOCTOU_SNIPPET, fifo, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode('utf-8', 'replace'))
        self.assertEqual(proc.stdout.decode().strip(), '[]')

    # -- scriptPath read is bounded by its OWN watchdog window (S3c Low-2) -------
    # O_NONBLOCK covers a FIFO; it does NOT bound a slow open()/read() of a REGULAR
    # file (a stalled network filesystem). That stall is SIMULATED by patching os.open
    # (or os.fdopen) to time.sleep for the target path only -- sleep is interrupted by
    # the SIGALRM handler's raise exactly like an EINTR-able syscall. A real FIFO
    # cannot reproduce it: the open is O_NONBLOCK, so a FIFO path never stalls here.
    def _stalling_open(self, target, stall=30.0):
        real_open = os.open

        def fake_open(path, *a, **kw):
            if path == target:
                time.sleep(stall)
            return real_open(path, *a, **kw)
        return mock.patch.object(cast_pretool_dispatch.os, 'open', side_effect=fake_open)

    def _read_timeout_lines(self):
        return [ln for ln in self._read_log().splitlines()
                if 'scriptPath read timed out' in ln]

    def test_blocked_scriptpath_open_allows_within_read_budget(self):
        path = self._write('stall.workflow.js', _WF_BAD)  # would DENY if it were read
        sentinel = self._arm_probe()
        with mock.patch.object(cast_pretool_dispatch, '_WORKFLOW_READ_BUDGET_SECS', 0.2), \
                self._stalling_open(path):
            t0 = time.monotonic()
            self._assert_allow(self._wf(scriptPath=path))
            elapsed = time.monotonic() - t0
        self.assertLess(elapsed, 1.5, 'stalled scriptPath read was not cut off')
        lines = self._read_timeout_lines()
        self.assertEqual(len(lines), 1)
        self.assertIn('budget 0.2s', lines[0])
        log = self._read_log()
        self.assertNotIn('stall.workflow.js', log)   # content-free: no path
        self.assertNotIn('stage-model lint timed out', log)  # the read, not the lint
        self._assert_timer_clean(sentinel)
        self.record_failure.assert_not_called()

    def test_blocked_scriptpath_open_uses_the_default_budget_inside_the_hook_timeout(self):
        d = cast_pretool_dispatch
        self.assertLess(d._WORKFLOW_READ_BUDGET_SECS + d._WORKFLOW_LINT_BUDGET_SECS, 5.0)
        path = self._write('stall.workflow.js', _WF_BAD)
        with self._stalling_open(path):
            t0 = time.monotonic()
            self._assert_allow(self._wf(scriptPath=path))
            elapsed = time.monotonic() - t0
        self.assertLess(elapsed, d._WORKFLOW_READ_BUDGET_SECS + 1.0)
        self.assertEqual(len(self._read_timeout_lines()), 1)

    def test_blocked_scriptpath_is_unreadable_not_a_skipped_call(self):
        # A stalled scriptPath behaves like any other unreadable scriptPath: an
        # inline `script` in the same call is still linted.
        path = self._write('stall.workflow.js', _WF_OK)
        with mock.patch.object(cast_pretool_dispatch, '_WORKFLOW_READ_BUDGET_SECS', 0.1), \
                self._stalling_open(path):
            self._assert_deny(self._wf(script=_WF_BAD, scriptPath=path))
            self._assert_allow(self._wf(script=_WF_OK, scriptPath=path))
        self.assertEqual(len(self._read_timeout_lines()), 2)

    def test_blocked_read_after_open_allows_and_closes_the_descriptor(self):
        path = self._write('stall.workflow.js', _WF_BAD)
        opened, closed = [], []
        real_open, real_close = os.open, os.close

        def spy_open(p, *a, **kw):
            fd = real_open(p, *a, **kw)
            if p == path:
                opened.append(fd)
            return fd

        def spy_close(fd):
            closed.append(fd)
            return real_close(fd)

        def stalled_fdopen(*a, **kw):
            time.sleep(30)
        sentinel = self._arm_probe()
        with mock.patch.object(cast_pretool_dispatch, '_WORKFLOW_READ_BUDGET_SECS', 0.2), \
                mock.patch.object(cast_pretool_dispatch.os, 'open', side_effect=spy_open), \
                mock.patch.object(cast_pretool_dispatch.os, 'close', side_effect=spy_close), \
                mock.patch.object(cast_pretool_dispatch.os, 'fdopen', side_effect=stalled_fdopen):
            self._assert_allow(self._wf(scriptPath=path))
        self.assertEqual(len(opened), 1)
        self.assertIn(opened[0], closed, 'descriptor leaked on a mid-read timeout')
        self.assertEqual(len(self._read_timeout_lines()), 1)
        self._assert_timer_clean(sentinel)

    def test_scriptpath_read_and_lint_use_separate_budget_windows(self):
        d = cast_pretool_dispatch
        path = self._write('ok.workflow.js', _WF_OK)
        with mock.patch.object(signal, 'setitimer', wraps=signal.setitimer) as spy:
            self._assert_allow(self._wf(scriptPath=path))
        r = signal.ITIMER_REAL
        self.assertEqual(spy.call_args_list, [
            mock.call(r, d._WORKFLOW_READ_BUDGET_SECS), mock.call(r, 0),
            mock.call(r, d._WORKFLOW_LINT_BUDGET_SECS), mock.call(r, 0)])

    def test_nul_and_lone_surrogate_scriptpaths_allow_quietly(self):
        for bad in ('a\x00b.js', '\ud800.js', '~\ud800/x.js'):
            with self.subTest(path=bad.encode('unicode_escape')):
                self._assert_allow(self._wf(scriptPath=bad))
        self.record_failure.assert_not_called()
        self.assertEqual(self._read_log(), '')

    def test_lint_returning_garbage_allows(self):
        lint = cast_pretool_dispatch._load(_LINT_MOD_NAME, _LINT_FILENAME)
        with mock.patch.object(lint, 'find_violations_in_source', return_value=None):
            self._assert_allow(self._wf(script=_WF_BAD))

    # -- scope: nothing else changes -------------------------------------
    def test_non_workflow_tool_with_same_input_is_unaffected(self):
        for tool in ('Agent', 'Glob', 'Read'):
            with self.subTest(tool=tool):
                payload = {'tool_name': tool,
                           'tool_input': {'script': _WF_BAD, 'subagent_type': 'x',
                                          'file_path': os.path.join(self._tmpdir, 'f')}}
                rc, out = self._run(payload)
                self.assertEqual(rc, 0)
                self.assertNotIn('"deny"', out)

    def test_lint_module_is_lazy_loaded_only_for_workflow(self):
        for tool in ('Agent', 'Glob'):
            self._run({'tool_name': tool, 'tool_input': {'subagent_type': 'x'}})
        self.assertNotIn(_LINT_MOD_NAME, cast_pretool_dispatch._MODULE_CACHE)
        self._run(self._wf(script=_WF_OK))
        self.assertIn(_LINT_MOD_NAME, cast_pretool_dispatch._MODULE_CACHE)

    def test_denies_in_subprocess_context_too(self):
        os.environ['CLAUDE_SUBPROCESS'] = '1'
        self._assert_deny(self._wf(script=_WF_BAD))

    # -- end-to-end through the real script ------------------------------
    def _child_env(self):
        env = dict(os.environ)
        env['HOME'] = self._tmpdir
        env['CAST_DB_PATH'] = os.path.join(self._tmpdir, 'nonexistent-cast.db')
        return env

    def _spawn(self, payload, timeout=60):
        return subprocess.run(
            [sys.executable, str(_SCRIPT_PATH)],
            input=json.dumps(payload).encode('utf-8'),
            capture_output=True, env=self._child_env(), timeout=timeout)

    def _spawn_snippet(self, snippet, *args, timeout=60):
        return subprocess.run(
            [sys.executable, '-c', snippet, str(_SCRIPT_PATH), *args],
            capture_output=True, env=self._child_env(), timeout=timeout)

    def test_e2e_script_deny(self):
        proc = self._spawn(self._wf(script=_WF_BAD))
        self.assertEqual(proc.returncode, 0)
        obj = json.loads(proc.stdout.decode('utf-8'))
        self.assertEqual(obj['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertIn('line 1', obj['hookSpecificOutput']['permissionDecisionReason'])

    def test_e2e_script_allow_is_silent(self):
        proc = self._spawn(self._wf(script=_WF_OK))
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b'')


class TestGuardFailureDedupe(_IsolatedHomeTestCase):
    """_record_guard_failure dedupes on the hook_failures table ITSELF -- no marker
    file anywhere (S3c round 2).

    Why: a marker file is steerable (a symlinked ~/.claude/run, an object planted at
    the marker path) and, written BEFORE the DB row, permanently lost later records
    when the DB write failed or when CLAUDE_SESSION_ID was unset ("unknown" shared by
    every session). Now: an existence check on (hook_name, session_id) before the
    write; any doubt -> write the row. Runs against a REAL temp cast.db (CAST_DB_PATH
    under the isolated HOME); setUp also reproduces the sandbox that made
    tempfile.gettempdir() fall back to the cwd (TMPDIR/TEMP/TMP unset, cwd = scratch).
    """

    SID = 'dedupe-session-1'
    HOOK = 'cast-pretool-dispatch/cast_git_guard'

    def setUp(self):
        super().setUp()
        env_patch = mock.patch.dict(os.environ)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        for k in ('TMPDIR', 'TEMP', 'TMP', 'CLAUDE_SESSION_ID'):
            os.environ.pop(k, None)
        self._cwd = tempfile.mkdtemp(prefix='cast-dedupe-cwd-')
        self.addCleanup(shutil.rmtree, self._cwd, ignore_errors=True)
        orig_cwd = os.getcwd()
        os.chdir(self._cwd)
        self.addCleanup(os.chdir, orig_cwd)
        gt = mock.patch.object(tempfile, 'gettempdir', return_value=self._cwd)
        gt.start()
        self.addCleanup(gt.stop)
        # cast_db._connect leaves sqlite connections to the GC (pre-existing, out of
        # scope here); keep its ResourceWarnings out of this class's output.
        wctx = warnings.catch_warnings()
        wctx.__enter__()
        self.addCleanup(wctx.__exit__, None, None, None)
        warnings.simplefilter('ignore', ResourceWarning)
        self.addCleanup(gc.collect)  # runs BEFORE the filter is popped (LIFO)
        self.db = os.environ['CAST_DB_PATH']
        if str(_SCRIPTS_DIR) not in sys.path:
            sys.path.insert(0, str(_SCRIPTS_DIR))
        import cast_db
        self.cast_db = cast_db

    def _record(self, mod='cast_git_guard', sid=SID, err='boom'):
        cast_pretool_dispatch._record_guard_failure(mod, err, sid)

    def _rows(self):
        if not os.path.exists(self.db):
            return []
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(
                'SELECT hook_name, session_id, exit_code, stderr FROM hook_failures '
                'ORDER BY timestamp, id').fetchall()
        except sqlite3.OperationalError:  # table never created
            return []
        finally:
            conn.close()

    def _guard_files(self):
        """Every file/dir/link named cast-pretool-guard* under HOME, cwd, or the
        system temp dirs (matching only this test's session ids in the shared ones)."""
        found = []
        for root in (self._tmpdir, self._cwd):
            for dirpath, dirnames, filenames in os.walk(root):
                found += [os.path.join(dirpath, n) for n in dirnames + filenames
                          if n.startswith('cast-pretool-guard')]
        for sysdir in ('/tmp/', '/var/tmp/'):
            if os.path.isdir(sysdir):
                found += [n for n in os.listdir(sysdir)
                          if n.startswith('cast-pretool-guard-dedupe-')]
        return found

    def test_same_session_and_module_is_recorded_once(self):
        self._record()
        self._record()
        self._record()
        rows = self._rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:3], (self.HOOK, self.SID, -1))
        self.assertIn('guard DISABLED', rows[0][3])
        self.assertEqual(self._guard_files(), [])

    def test_other_session_and_other_module_are_recorded_separately(self):
        self._record('cast_git_guard', 'dedupe-session-1')
        self._record('cast_command_guard', 'dedupe-session-1')
        self._record('cast_git_guard', 'dedupe-session-2')
        self._record('cast_git_guard', 'dedupe-session-2')  # dup of the third
        pairs = sorted((r[0], r[1]) for r in self._rows())
        self.assertEqual(pairs, sorted([
            ('cast-pretool-dispatch/cast_git_guard', 'dedupe-session-1'),
            ('cast-pretool-dispatch/cast_command_guard', 'dedupe-session-1'),
            ('cast-pretool-dispatch/cast_git_guard', 'dedupe-session-2')]))

    def test_payload_session_id_wins_over_the_env_fallback(self):
        os.environ['CLAUDE_SESSION_ID'] = 'env-session'
        self._record(sid='payload-session')
        self._record(sid='payload-session-2')   # same env, new payload -> new row
        self._record(sid=None)                  # no payload id -> env fallback
        self._record(sid=None)                  # ... deduped on the env id
        self.assertEqual(sorted(r[1] for r in self._rows()),
                         ['env-session', 'payload-session', 'payload-session-2'])

    def test_unusable_session_id_records_every_time_as_unknown(self):
        bad = ['', None, 123, 'unknown', 'has space', 'new\nline', 'x' * 65, ['a']]
        for sid in bad:
            with self.subTest(sid=repr(sid)[:20]):
                before = len(self._rows())
                self._record(sid=sid)
                self._record(sid=sid)
                self.assertEqual(len(self._rows()) - before, 2)
        self.assertEqual({r[1] for r in self._rows()}, {'unknown'})
        self.assertEqual(self._guard_files(), [])

    def test_unset_env_session_does_not_suppress_other_sessions(self):
        # The old marker keyed an unset CLAUDE_SESSION_ID as "unknown" for everyone.
        self._record(sid=None)
        self._record(sid='real-session')
        self.assertEqual(sorted(r[1] for r in self._rows()), ['real-session', 'unknown'])

    def test_planted_objects_under_run_have_no_effect(self):
        run = os.path.join(self._tmpdir, '.claude', 'run')
        outside = os.path.join(self._tmpdir, 'outside')
        os.makedirs(outside)
        os.makedirs(os.path.dirname(run), exist_ok=True)
        os.symlink(outside, run)                       # symlinked ~/.claude/run
        name = 'cast-pretool-guard-%s-cast_git_guard.marker' % self.SID
        os.symlink(os.path.join(outside, 'target'), os.path.join(outside, name))
        os.mkfifo(os.path.join(outside, 'cast-pretool-guard-fifo'))
        self._record()
        self._record()
        self.assertEqual(len(self._rows()), 1)         # recorded, deduped by the DB
        self.assertEqual(sorted(os.listdir(outside)),
                         sorted([name, 'cast-pretool-guard-fifo']))  # untouched
        self.assertFalse(os.path.exists(os.path.join(outside, 'target')))

    def test_db_write_failure_on_first_call_does_not_lose_the_second(self):
        real = self.cast_db.db_write
        with mock.patch.object(self.cast_db, 'db_write', side_effect=[False, None]) as w:
            self._record()
        self.assertEqual(w.call_count, 1)
        self.assertEqual(self._rows(), [])             # call 1 wrote nothing
        self.assertIs(self.cast_db.db_write, real)
        self._record()                                 # call 2: nothing blocks it
        self.assertEqual(len(self._rows()), 1)

    def test_unreadable_dedupe_check_still_records(self):
        with mock.patch.object(self.cast_db, 'db_query', side_effect=RuntimeError('boom')):
            self._record()
        self.assertEqual(len(self._rows()), 1)
        with mock.patch.object(self.cast_db, 'db_query', return_value=[]):
            self._record()                             # query says "none" -> writes
        self.assertEqual(len(self._rows()), 2)

    def test_never_raises_when_the_db_layer_blows_up(self):
        with mock.patch.object(self.cast_db, 'log_hook_failure',
                               side_effect=RuntimeError('db down')):
            self.assertIsNone(
                cast_pretool_dispatch._record_guard_failure('cast_git_guard', 'boom', self.SID))
        self.assertIn('_record_guard_failure', self._read_log())

    def test_no_marker_file_is_created_anywhere(self):
        for mod in ('cast_git_guard', 'cast_command_guard', 'cast_egress_sentinel'):
            self._record(mod)
            self._record(mod)
        self.assertEqual(len(self._rows()), 3)
        self.assertEqual(self._guard_files(), [])
        self.assertFalse(os.path.exists(os.path.join(self._tmpdir, '.claude', 'run')))

    def test_e2e_real_script_dedupes_on_the_payload_session_id(self):
        # Real default path, nothing mocked: a copy of the dispatcher with a broken
        # sibling guard, HOME isolated, TMPDIR/TEMP/TMP unset, cwd = scratch dir. The
        # env CLAUDE_SESSION_ID deliberately differs from the payload session_id.
        session = 'dedupe-e2e-' + uuid.uuid4().hex[:12]
        scripts = os.path.join(self._tmpdir, 'scripts')
        os.mkdir(scripts)
        for name in ('cast-pretool-dispatch.py', 'cast_db.py'):
            shutil.copy(str(_SCRIPTS_DIR / name), scripts)
        with open(os.path.join(scripts, 'cast-git-guard.py'), 'w') as fh:
            fh.write('raise ImportError("intentional test failure")\n')
        env = dict(os.environ)
        env.update(HOME=self._tmpdir, CLAUDE_SESSION_ID='env-session-ignored',
                   CAST_DB_PATH=self.db)
        for k in ('TMPDIR', 'TEMP', 'TMP', 'CLAUDE_SUBPROCESS'):
            env.pop(k, None)
        payload = {'tool_name': 'Bash', 'tool_input': {'command': 'echo hello'},
                   'session_id': session}
        for _ in range(2):
            proc = subprocess.run(
                [sys.executable, os.path.join(scripts, 'cast-pretool-dispatch.py')],
                input=json.dumps(payload).encode('utf-8'), capture_output=True,
                env=env, cwd=self._cwd, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr.decode('utf-8', 'replace'))
        git_rows = [r for r in self._rows() if r[0] == self.HOOK]
        self.assertEqual([r[1] for r in git_rows], [session])   # one row, payload id
        self.assertNotIn('env-session-ignored', {r[1] for r in self._rows()})
        self.assertEqual(self._guard_files(), [])
        self.assertEqual([n for n in os.listdir('/tmp/') if session in n], [])


class TestDegradedGitBlockFailClosed(unittest.TestCase):
    """_degraded_git_block must never ALLOW because its own scan failed (a hook crash or
    timeout is an allow, so an exception inside the check cannot be a pass)."""

    def setUp(self):
        patch = mock.patch.object(cast_pretool_dispatch, '_log_error')
        self.log_error = patch.start()
        self.addCleanup(patch.stop)

    def test_scan_exception_blocks_a_command_naming_git_without_echoing_the_error(self):
        with mock.patch.object(cast_pretool_dispatch, '_degraded_git_scan',
                               side_effect=RuntimeError('secret-boom')):
            msg = cast_pretool_dispatch._degraded_git_block('git status')
        self.assertIsInstance(msg, str)
        self.assertIn('RuntimeError', msg)
        self.assertNotIn('secret-boom', msg)
        self.assertNotIn('secret-boom', ' '.join(str(c) for c in self.log_error.call_args_list))
        self.assertTrue(self.log_error.called)

    def test_scan_exception_still_allows_a_command_that_cannot_name_git(self):
        # Keeps `bash install.sh` (the repair) usable even if the scan itself is broken.
        with mock.patch.object(cast_pretool_dispatch, '_degraded_git_scan',
                               side_effect=RuntimeError('boom')):
            self.assertIsNone(cast_pretool_dispatch._degraded_git_block('bash install.sh'))

    def test_non_string_command_is_not_runnable_and_is_ignored(self):
        self.assertIsNone(cast_pretool_dispatch._degraded_git_block(['git', 'push']))
        self.assertIsNone(cast_pretool_dispatch._degraded_git_block(None))

    def test_hatch_lookup_is_done_once_not_per_match(self):
        # 3000 `git push` matches but a single hatch pass: the substring probe runs once per
        # distinct hatch token (<= 8), never once per match.
        class CountingStr(str):
            probes = 0

            def __contains__(self, item):
                if item in cast_pretool_dispatch._DEGRADED_GIT_HATCHES.values():
                    CountingStr.probes += 1
                return str.__contains__(self, item)
        cmd = CountingStr('git push;' * 3000 + 'git reset --hard')
        msg = cast_pretool_dispatch._degraded_git_block(cmd)
        self.assertIn('git push', msg)
        self.assertLessEqual(CountingStr.probes, len(cast_pretool_dispatch._DEGRADED_GIT_HATCHES))


if __name__ == '__main__':
    unittest.main()
