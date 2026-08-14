#!/usr/bin/env python3
"""Tests for scripts/cast_handoff_parser.py — ## Handoff block validation.

Covers:
  - NEEDS_CONTEXT accepted as a valid status. It was missing from the enum
    (only DONE/DONE_WITH_CONCERNS/BLOCKED were allowed) despite being part of
    the documented global agent contract since 2026-07-10 — 41 agent responses
    were wrongly logged as protocol violations 2026-07-02..2026-08-04 (see
    agent_protocol_violations, pattern='invalid_value:status=NEEDS_CONTEXT').
  - DONE / DONE_WITH_CONCERNS / BLOCKED still accepted; a bogus value still
    rejected.
  - Markdown-emphasis-wrapped and trailing-prose status values are accepted
    (real invalid_value rows from the same window: "**DONE** — All gates
    pass...", "BLOCKED (verdict stated as text...)",
    "DONE_WITH_CONCERNS — **APPROVE** (ad-hoc dispatch...)").
  - Empty / missing status is still rejected.
  - Parity between this module's status enum and the inline fallback copy in
    scripts/cast_subagent_stop.py (_inline_validate_handoff /
    _INLINE_STATUS_VALUES) — the two drifted apart once already; this test is
    the enforcement mechanism referenced in both files' "KEEP IN SYNC" comments.
  - Parity against the JSON schema copies of the same enum (stdlib json.load
    only — no jsonschema dependency): schemas/agent-handoff.json and
    schemas/status-block.schema.json describe the identical 4-value field and
    must match exactly; schemas/agent-status.json describes the WIDER general
    Status-block field (adds reviewer-only APPROVE/REQUEST_CHANGES) and is
    checked as a superset, not an exact match. A repo-wide audit
    (2026-08-14) found schemas/agent-handoff.json was a third stale 3-value
    copy of the same bug fixed above; it was corrected alongside this test.
"""
import json
import sys
import unittest
from pathlib import Path

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
_SCHEMAS_DIR = Path(__file__).parent.parent / 'schemas'

import cast_handoff_parser  # noqa: E402
import cast_subagent_stop  # noqa: E402


def _handoff_text(status: str, files_changed: str = 'none', blockers: str = 'none') -> str:
    """Build a minimal valid ## Handoff block body with the given status value."""
    return (
        'Some agent prose above.\n\n'
        '## Handoff\n'
        f'files_changed: {files_changed}\n'
        f'status: {status}\n'
        f'blockers: {blockers}\n'
    )


class TestStatusEnumAcceptsNeedsContext(unittest.TestCase):
    """The documented global contract (Status: DONE | DONE_WITH_CONCERNS |
    BLOCKED | NEEDS_CONTEXT) must be accepted end-to-end."""

    def test_needs_context_accepted(self):
        result = cast_handoff_parser.validate_handoff(_handoff_text('NEEDS_CONTEXT'))
        self.assertTrue(result['ok'], result)

    def test_done_still_accepted(self):
        result = cast_handoff_parser.validate_handoff(_handoff_text('DONE'))
        self.assertTrue(result['ok'], result)

    def test_done_with_concerns_still_accepted(self):
        result = cast_handoff_parser.validate_handoff(_handoff_text('DONE_WITH_CONCERNS'))
        self.assertTrue(result['ok'], result)

    def test_blocked_still_accepted(self):
        result = cast_handoff_parser.validate_handoff(_handoff_text('BLOCKED'))
        self.assertTrue(result['ok'], result)

    def test_bogus_value_still_rejected(self):
        result = cast_handoff_parser.validate_handoff(_handoff_text('MAYBE'))
        self.assertFalse(result['ok'])
        self.assertEqual(result['violation'], 'handoff_schema_violation')
        self.assertEqual(result['pattern'], 'invalid_value:status=MAYBE')

    def test_lowercase_value_still_rejected(self):
        """Case matters — lowercase is not tolerated as markdown/prose noise."""
        result = cast_handoff_parser.validate_handoff(_handoff_text('done'))
        self.assertFalse(result['ok'])


class TestStatusMarkdownAndProseTolerance(unittest.TestCase):
    """Real invalid_value rows from agent_protocol_violations (2026-07-02..
    2026-08-04): the intended status was unambiguous but got rejected because of
    surrounding markdown emphasis / trailing prose."""

    def test_bold_wrapped_done_accepted(self):
        result = cast_handoff_parser.validate_handoff(
            _handoff_text('**DONE** — All gates pass, ready to merge')
        )
        self.assertTrue(result['ok'], result)

    def test_blocked_with_trailing_parenthetical_accepted(self):
        result = cast_handoff_parser.validate_handoff(
            _handoff_text('BLOCKED (verdict stated as text, not enum)')
        )
        self.assertTrue(result['ok'], result)

    def test_done_with_concerns_with_trailing_prose_accepted(self):
        result = cast_handoff_parser.validate_handoff(
            _handoff_text('DONE_WITH_CONCERNS — **APPROVE** (ad-hoc dispatch, no task_id)')
        )
        self.assertTrue(result['ok'], result)

    def test_italic_wrapped_needs_context_accepted(self):
        """Underscore is both a legal mid-token char (DONE_WITH_CONCERNS) and a
        markdown italic delimiter — the closing wrapper must not be mistaken for
        part of the token, nor swallow the token's own internal underscores."""
        result = cast_handoff_parser.validate_handoff(_handoff_text('_NEEDS_CONTEXT_'))
        self.assertTrue(result['ok'], result)

    def test_pure_markdown_noise_still_rejected(self):
        """No leading uppercase token at all -> still invalid, not silently accepted."""
        result = cast_handoff_parser.validate_handoff(_handoff_text('***'))
        self.assertFalse(result['ok'])

    def test_wrong_word_glued_to_valid_prefix_still_rejected(self):
        """Guards against accidental prefix-matching: DONEZZZ must not match DONE."""
        result = cast_handoff_parser.validate_handoff(_handoff_text('DONEZZZ'))
        self.assertFalse(result['ok'])


class TestStatusMissingOrEmpty(unittest.TestCase):

    def test_missing_status_field_rejected(self):
        text = '## Handoff\nfiles_changed: none\nblockers: none\n'
        result = cast_handoff_parser.validate_handoff(text)
        self.assertFalse(result['ok'])
        self.assertEqual(result['pattern'], 'missing_field:status')

    def test_empty_status_value_rejected(self):
        text = '## Handoff\nfiles_changed: none\nstatus: \nblockers: none\n'
        result = cast_handoff_parser.validate_handoff(text)
        self.assertFalse(result['ok'])
        self.assertEqual(result['pattern'], 'empty_field:status')


class TestNormalizeEnumValueHelper(unittest.TestCase):
    """Direct coverage of _normalize_enum_value, the extraction primitive."""

    def test_strips_bold_markers(self):
        self.assertEqual(cast_handoff_parser._normalize_enum_value('**DONE**'), 'DONE')

    def test_strips_wrapping_underscores_preserves_internal(self):
        self.assertEqual(
            cast_handoff_parser._normalize_enum_value('_DONE_WITH_CONCERNS_'),
            'DONE_WITH_CONCERNS',
        )

    def test_stops_at_first_non_token_char(self):
        self.assertEqual(
            cast_handoff_parser._normalize_enum_value('BLOCKED (reason...)'),
            'BLOCKED',
        )

    def test_no_leading_token_returns_empty(self):
        self.assertEqual(cast_handoff_parser._normalize_enum_value('not sure'), '')
        self.assertEqual(cast_handoff_parser._normalize_enum_value('***'), '')
        self.assertEqual(cast_handoff_parser._normalize_enum_value(''), '')


class TestInlineFallbackAcceptsNeedsContext(unittest.TestCase):
    """scripts/cast_subagent_stop.py's _inline_validate_handoff is a second,
    independently-maintained copy of this same validator, used only when
    cast_handoff_parser fails to import. It must accept the same values."""

    def test_needs_context_accepted(self):
        result = cast_subagent_stop._inline_validate_handoff(_handoff_text('NEEDS_CONTEXT'))
        self.assertTrue(result['ok'], result)

    def test_done_with_concerns_still_accepted(self):
        result = cast_subagent_stop._inline_validate_handoff(
            _handoff_text('DONE_WITH_CONCERNS')
        )
        self.assertTrue(result['ok'], result)

    def test_bogus_value_still_rejected(self):
        result = cast_subagent_stop._inline_validate_handoff(_handoff_text('MAYBE'))
        self.assertFalse(result['ok'])

    def test_bold_wrapped_done_accepted(self):
        result = cast_subagent_stop._inline_validate_handoff(
            _handoff_text('**DONE** — All gates pass, ready to merge')
        )
        self.assertTrue(result['ok'], result)

    def test_blocked_with_trailing_parenthetical_accepted(self):
        result = cast_subagent_stop._inline_validate_handoff(
            _handoff_text('BLOCKED (verdict stated as text, not enum)')
        )
        self.assertTrue(result['ok'], result)

    def test_italic_wrapped_needs_context_accepted(self):
        result = cast_subagent_stop._inline_validate_handoff(_handoff_text('_NEEDS_CONTEXT_'))
        self.assertTrue(result['ok'], result)


class TestStatusEnumParity(unittest.TestCase):
    """The regression guard for the actual root-cause bug: the two hardcoded
    copies of the status enum (cast_handoff_parser._REQUIRED_FIELDS['status'] and
    cast_subagent_stop._INLINE_STATUS_VALUES) must contain exactly the same
    values. Neither file can import the other's constant at runtime (see the
    KEEP IN SYNC comments at both definitions) — this test is the sync
    mechanism that replaces that import."""

    def test_status_enums_match(self):
        canonical = cast_handoff_parser._REQUIRED_FIELDS['status']
        inline = set(cast_subagent_stop._INLINE_STATUS_VALUES)
        self.assertEqual(
            canonical, inline,
            f'status enum drift: canonical={sorted(canonical)} inline={sorted(inline)}',
        )

    def test_status_enum_matches_documented_global_contract(self):
        """rules/working-conventions.md mandates exactly these four values."""
        expected = {'DONE', 'DONE_WITH_CONCERNS', 'BLOCKED', 'NEEDS_CONTEXT'}
        self.assertEqual(cast_handoff_parser._REQUIRED_FIELDS['status'], expected)

    @staticmethod
    def _load_schema_status_enum(filename: str) -> set:
        """Load a schemas/*.json file with stdlib json.load (no jsonschema
        dependency) and return its properties.status.enum as a set."""
        with open(_SCHEMAS_DIR / filename) as f:
            schema = json.load(f)
        return set(schema['properties']['status']['enum'])

    def test_agent_handoff_json_schema_matches_canonical_enum(self):
        """schemas/agent-handoff.json describes the exact same Handoff-block
        status field as _REQUIRED_FIELDS['status'] — a third copy of the same
        enum, found stale (missing NEEDS_CONTEXT) in the same 2026-08-14 audit
        that led to this test and fixed alongside it."""
        schema_enum = self._load_schema_status_enum('agent-handoff.json')
        canonical = cast_handoff_parser._REQUIRED_FIELDS['status']
        self.assertEqual(
            schema_enum, canonical,
            f'schemas/agent-handoff.json status enum drift: '
            f'schema={sorted(schema_enum)} canonical={sorted(canonical)}',
        )

    def test_status_block_schema_matches_canonical_enum(self):
        """schemas/status-block.schema.json describes the general agent
        Status: line — which schemas/agent-handoff.json's own field
        description says the Handoff status field "mirrors" — so the two are
        expected to stay identical, not just overlapping."""
        schema_enum = self._load_schema_status_enum('status-block.schema.json')
        canonical = cast_handoff_parser._REQUIRED_FIELDS['status']
        self.assertEqual(
            schema_enum, canonical,
            f'schemas/status-block.schema.json status enum drift: '
            f'schema={sorted(schema_enum)} canonical={sorted(canonical)}',
        )

    def test_agent_status_schema_is_superset_of_canonical_enum(self):
        """schemas/agent-status.json's status enum is intentionally WIDER than
        the Handoff-block's four values — it adds reviewer-only terminal
        verdicts (APPROVE, REQUEST_CHANGES) from code-reviewer/pr-reviewer that
        are never valid in a Handoff status field. Assert superset, not
        equality: this schema must never DROP one of the 4 core values, but is
        allowed additional reviewer-specific ones."""
        schema_enum = self._load_schema_status_enum('agent-status.json')
        canonical = cast_handoff_parser._REQUIRED_FIELDS['status']
        self.assertTrue(
            canonical.issubset(schema_enum),
            f'schemas/agent-status.json is missing core values: {canonical - schema_enum}',
        )


if __name__ == '__main__':
    unittest.main()
