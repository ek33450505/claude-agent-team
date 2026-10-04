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

    def test_watchdog_armed_only_around_the_lint_itself(self):
        # Not for other tools, and not for any Workflow input that short-circuits
        # before linting (name-only, over either bound).
        too_big = _WF_BAD + ' ' * (256 * 1024 + 1)
        cases = [
            {'tool_name': 'Agent', 'tool_input': {'subagent_type': 'x'}},
            {'tool_name': 'Glob', 'tool_input': {}},
            self._wf(name='saved-workflow'),
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


if __name__ == '__main__':
    unittest.main()
