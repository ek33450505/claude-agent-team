#!/usr/bin/env python3
"""Tests for scripts/cast-lint-workflow-stage-models.py.

These are the mutation tests for the gate, kept as real tests so the gate
cannot quietly become one that *cannot* fail. Each case states what a PASSING
check looks like while the bug is still present:

  M1  a stage with model: removed          -> MUST be reported
  M2  model: present only in a comment or
      prompt string, not as a real option  -> MUST still be reported
  M4  a bare opt-out marker with no reason -> MUST still be reported
  M5  a nested inner stage pinning a model -> MUST NOT satisfy the outer one

M2 and M5 are the ones that matter: both are shapes where a naive substring
scan would report a false PASS.

The lint is hermetic (it reads workflows/ under the repo root), so these tests
drive find_violations(path) directly against temp fixture files and never touch
the repo's real workflows/ directory.
"""
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

_LINT_PATH = (
    Path(__file__).parent.parent / 'scripts' / 'cast-lint-workflow-stage-models.py'
)

_spec = importlib.util.spec_from_file_location('cast_lint_workflow_stage_models', _LINT_PATH)
lint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lint)


class WorkflowStageModelLintTest(unittest.TestCase):
    def _violations(self, source):
        """Write source to a temp .workflow.js and return the lint's findings."""
        fd, path = tempfile.mkstemp(suffix='.workflow.js')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as fh:
                fh.write(source)
            return lint.find_violations(path)
        finally:
            os.unlink(path)

    # --- M0: the compliant shape must be accepted -------------------------
    def test_stage_with_explicit_model_is_clean(self):
        self.assertEqual(
            self._violations("const x = await agent(P, { label: 'a', model: 'haiku' })\n"),
            [],
        )

    # --- M1: the gate must bite when the fix is reverted ------------------
    def test_stage_without_model_is_reported(self):
        found = self._violations("const x = await agent(P, { label: 'a' })\n")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][0], 1)

    # --- M2: false-proxy guard (a substring scan would pass this) ---------
    def test_model_in_comment_or_prompt_string_does_not_count(self):
        src = (
            "// model: 'haiku' would be nice here\n"
            "const x = await agent(`pick a model: haiku or opus`, { label: 'a' })\n"
        )
        found = self._violations(src)
        self.assertEqual(len(found), 1, 'model: in a comment/string must not satisfy the gate')
        self.assertEqual(found[0][0], 2)

    # --- M3: the documented escape hatch must actually work ---------------
    def test_opt_out_with_reason_is_accepted(self):
        src = (
            "// cast-lint: inherit-model -- final adversarial judge needs session opus\n"
            "const x = await agent(P, { label: 'a' })\n"
        )
        self.assertEqual(self._violations(src), [])

    # --- M4: the hatch must not be usable as a bare silencer --------------
    def test_opt_out_without_reason_is_still_reported(self):
        src = "// cast-lint: inherit-model\nconst x = await agent(P, { label: 'a' })\n"
        self.assertEqual(len(self._violations(src)), 1)

    # --- M5: an inner stage's model must not satisfy the outer call -------
    def test_nested_inner_model_does_not_satisfy_outer(self):
        src = (
            "const x = await agent(await agent(P, { label: 'in', model: 'haiku' }), "
            "{ label: 'out' })\n"
        )
        found = self._violations(src)
        self.assertEqual(len(found), 1, "inner model: must not satisfy the outer agent()")

    # --- offsets: reported line numbers must survive blanking -------------
    def test_line_numbers_survive_comment_and_string_blanking(self):
        src = (
            "/* a block comment\n   spanning lines */\n"
            "const s = `a template\nspanning lines`\n"
            "const x = await agent(P, { label: 'a' })\n"
        )
        found = self._violations(src)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][0], 5, 'line number must point at the real agent() call')

    # --- regex literals: the defect the review gate caught ----------------
    def test_regex_literal_with_unmatched_quote_does_not_blind_the_lint(self):
        """A regex containing one quote must not swallow the rest of the file.

        Before regex lexing this returned 0 violations (silent false negative) --
        the worst outcome a gate can produce.
        """
        src = "const re = /['\"]/\nconst x = await agent(P, { label: 'no-model' })\n"
        found = self._violations(src)
        self.assertEqual(len(found), 1, 'regex literal must not hide a later agent() call')
        self.assertEqual(found[0][0], 2)

    def test_regex_with_even_quotes_also_does_not_blind_the_lint(self):
        src = "const re = /['\"]['\"]/\nconst x = await agent(P, { label: 'no-model' })\n"
        self.assertEqual(len(self._violations(src)), 1)

    def test_slash_inside_character_class_does_not_close_the_regex(self):
        src = "const re = /[/'\"]/\nconst x = await agent(P, { label: 'a' })\n"
        self.assertEqual(len(self._violations(src)), 1)

    def test_model_inside_a_regex_does_not_satisfy_the_gate(self):
        src = "const re = /model:/\nconst x = await agent(P, { label: 'a' })\n"
        self.assertEqual(len(self._violations(src)), 1)

    def test_division_is_not_misread_as_a_regex(self):
        src = "const r = total / count\nconst x = await agent(P, { label: 'a' })\n"
        found = self._violations(src)
        self.assertEqual(len(found), 1, 'division must not start a regex and blank the file')
        self.assertEqual(found[0][0], 2)

    # --- fail-closed: never report zero over an unparseable file ----------
    def test_unterminated_string_is_reported_as_a_parse_anomaly(self):
        src = "const s = 'oops\nconst x = await agent(P, { label: 'a' })\n"
        found = self._violations(src)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][0], 0, 'anomaly rows carry line 0')
        self.assertIn('PARSE ANOMALY', found[0][1])

    # --- find_violations_in_source: the string-level API the PreToolUse
    # --- Workflow guard reuses (find_violations(path) delegates to it) ------
    def test_in_source_reports_violation_records_and_no_anomaly(self):
        src = "const a = await agent(P, { label: 'a' })\n"
        found, unterminated = lint.find_violations_in_source(src)
        self.assertEqual(found, [(1, "const a = await agent(P, { label: 'a' })")])
        self.assertIsNone(unterminated)

    def test_in_source_clean_source_returns_empty(self):
        found, unterminated = lint.find_violations_in_source(
            "const a = await agent(P, { model: 'haiku' })\n")
        self.assertEqual(found, [])
        self.assertIsNone(unterminated)

    def test_in_source_signals_unterminated_quote_without_certifying(self):
        # Everything after the open quote is blanked, so the agent() call is
        # invisible: the signal must surface (violations alone would read clean).
        src = "const s = 'oops\nconst x = await agent(P, { label: 'a' })\n"
        found, unterminated = lint.find_violations_in_source(src)
        self.assertEqual(found, [])
        self.assertEqual(unterminated, "'")

    def test_in_source_honours_opt_out_on_line_above(self):
        src = ("// cast-lint: inherit-model -- needs session opus\n"
               "const a = await agent(P, { label: 'a' })\n")
        self.assertEqual(lint.find_violations_in_source(src), ([], None))

    def test_in_source_nested_inner_model_does_not_satisfy_outer(self):
        src = "await agent(await agent(P, { model: 'haiku' }), { label: 'o' })\n"
        found, _ = lint.find_violations_in_source(src)
        self.assertEqual([ln for ln, _ in found], [1])

    def test_many_sequential_calls_are_linear_not_quadratic(self):
        # The nested-span scan must stop at the first call that starts past this
        # call's span. Without that break, 30k sequential calls take ~15 s;
        # with it, well under one. Generous bound to stay non-flaky.
        import time
        src = "agent(P);\n" * 30000
        t0 = time.time()
        found, unterminated = lint.find_violations_in_source(src)
        elapsed = time.time() - t0
        self.assertEqual(len(found), 30000)
        self.assertIsNone(unterminated)
        self.assertLess(elapsed, 5.0, 'nested-span loop looks quadratic again')

    def test_early_break_still_blanks_deeply_nested_inner_models(self):
        # inner-most has model; the two outer calls must still be reported (both on
        # line 1), and
        # a sibling AFTER the nest (past the break point) must be judged alone.
        src = ("agent(agent(agent(P, { model: 'haiku' })))\n"
               "agent(P, { model: 'sonnet' })\n"
               "agent(P)\n")
        found, _ = lint.find_violations_in_source(src)
        self.assertEqual([ln for ln, _ in found], [1, 1, 3])

    def test_path_api_matches_source_api(self):
        src = "x\nconst a = await agent(P, { label: 'a' })\n"
        fd, path = tempfile.mkstemp(suffix='.workflow.js')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as fh:
                fh.write(src)
            self.assertEqual(lint.find_violations(path),
                             lint.find_violations_in_source(src)[0])
        finally:
            os.unlink(path)

    # --- the repo's own workflows must be clean ---------------------------
    def test_repo_workflows_pin_every_stage_model(self):
        wf_dir = Path(__file__).parent.parent / 'workflows'
        if not wf_dir.is_dir():
            self.skipTest('no workflows/ directory')
        offenders = {}
        for path in sorted(wf_dir.glob('*.workflow.js')):
            found = lint.find_violations(str(path))
            if found:
                offenders[path.name] = found
        self.assertEqual(offenders, {}, f'unpinned workflow stages: {offenders}')


if __name__ == '__main__':
    unittest.main()
