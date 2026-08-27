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


class TestKeyDecorationTolerance(unittest.TestCase):
    """DOC-2: the parser tolerated markdown in enum VALUES but not in KEYS.

    Measured 2026-08-27 over the live agent_protocol_violations table: 1,629 of
    2,555 rows (63%) were `missing_field:files_changed` or
    `empty_field:files_changed`, and sampling showed the handoffs behind them were
    complete and well-formed. Two root causes, both reproduced against the parser
    before the fix: `**files_changed:** a.py` partitions on the first ':' into the
    key `**files_changed`, and `files_changed:` with a bullet list beneath reads as
    an empty value. Real violations were buried roughly 40:1.

    Each case below is a shape taken from those rows. The rejection cases matter
    at least as much: this tolerance must not turn a genuinely malformed handoff
    into a passing one.
    """

    def _ok(self, body):
        return cast_handoff_parser.validate_handoff('## Handoff\n' + body)

    def test_markdown_emphasised_keys_are_accepted(self):
        r = self._ok('**files_changed:** a.py\n**status:** DONE\n**blockers:** none\n')
        self.assertTrue(r['ok'], r)

    def test_underscore_and_backtick_emphasised_keys_are_accepted(self):
        for body in ('_files_changed_: a.py\n_status_: DONE\n_blockers_: none\n',
                     '`files_changed`: a.py\n`status`: DONE\n`blockers`: none\n'):
            self.assertTrue(self._ok(body)['ok'], body)

    def test_bulleted_key_lines_are_accepted(self):
        r = self._ok('- **files_changed:** a.py\n- **status:** DONE\n- **blockers:** none\n')
        self.assertTrue(r['ok'], r)

    def test_json_quoted_keys_are_accepted(self):
        r = self._ok('"files_changed": ["a.py"]\n"status": "DONE"\n"blockers": "none"\n')
        self.assertTrue(r['ok'], r)

    def test_space_separated_key_words_are_accepted(self):
        r = self._ok('Files changed: a.py\nStatus: DONE\nBlockers: none\n')
        self.assertTrue(r['ok'], r)

    def test_list_beneath_a_key_becomes_its_value(self):
        r = self._ok('files_changed:\n- a.py\n- b.py\nstatus: DONE\nblockers: none\n')
        self.assertTrue(r['ok'], r)
        fields = cast_handoff_parser._parse_kv('files_changed:\n- a.py\n- b.py\n')
        self.assertEqual(fields['files_changed'], 'a.py, b.py')

    def test_numbered_list_beneath_a_key_becomes_its_value(self):
        r = self._ok('files_changed:\n1. a.py\n2. b.py\nstatus: DONE\nblockers: none\n')
        self.assertTrue(r['ok'], r)

    def test_blank_line_closes_a_list_continuation(self):
        """The real rows put a blank line between the list and the next key."""
        r = self._ok('files_changed:\n- a.py\n\nstatus: DONE\nblockers: none\n')
        self.assertTrue(r['ok'], r)

    def test_a_bulleted_required_key_is_not_swallowed_by_a_list(self):
        """A list continuation must not eat the next required field. Without the
        guard, `- **status:** DONE` reads as another files_changed entry and the
        status field vanishes — the fix would have destroyed data it was meant to
        recover."""
        r = self._ok('files_changed:\n- a.py\n- **status:** DONE\n- **blockers:** none\n')
        self.assertTrue(r['ok'], r)
        self.assertIsNone(r['pattern'])

    # --- the tolerance must not manufacture passes -------------------------

    def test_a_genuinely_absent_field_is_still_missing(self):
        r = self._ok('status: DONE\nblockers: none\n')
        self.assertEqual(r['pattern'], 'missing_field:files_changed')

    def test_an_empty_key_with_nothing_beneath_it_is_still_empty(self):
        r = self._ok('files_changed:\nstatus: DONE\nblockers: none\n')
        self.assertEqual(r['pattern'], 'empty_field:files_changed')

    def test_prose_beneath_an_empty_key_is_not_absorbed(self):
        """Only list items continue a key. Free prose does not, so a field that
        was never given a value still reads as empty."""
        r = self._ok('files_changed:\nI changed nothing\nstatus: DONE\nblockers: none\n')
        self.assertEqual(r['pattern'], 'empty_field:files_changed')

    def test_emphasis_wrapper_with_no_content_is_empty_not_the_wrapper(self):
        """`**blockers:**` alone must reduce to an empty value. Stripping only the
        KEY would leave the value as the literal string '**', which is non-empty
        and would have passed — a false green created by the fix itself."""
        r = self._ok('**files_changed:** a.py\n**status:** DONE\n**blockers:**\n')
        self.assertEqual(r['pattern'], 'empty_field:blockers')

    def test_a_differently_named_field_is_still_a_violation(self):
        """Folding whitespace to '_' maps `files changed` onto the required field,
        but must not map a different field onto it: `files staged` becomes
        `files_staged` and stays the genuine violation it is."""
        r = self._ok('files staged: a.py\nstatus: DONE\nblockers: none\n')
        self.assertEqual(r['pattern'], 'missing_field:files_changed')

    def test_an_invalid_status_still_fails_through_an_emphasised_key(self):
        r = self._ok('**files_changed:** a.py\n**status:** APPROVED\n**blockers:** none\n')
        self.assertEqual(r['pattern'], 'invalid_value:status=APPROVED')

    def test_a_plain_key_leaves_its_value_untouched(self):
        """The closing half of an emphasis wrapper is stripped from the value only
        when the key opened one. A plainly-written key keeps its value byte for
        byte, so a leading-'*' glob survives."""
        self.assertEqual(cast_handoff_parser._parse_kv('files_changed: *.py\n')['files_changed'], '*.py')
        self.assertEqual(cast_handoff_parser._parse_kv('files changed: *.py\n')['files_changed'], '*.py')


class TestKeyDecorationParity(unittest.TestCase):
    """The inline fallback in cast_subagent_stop.py carries its own copy of the
    key normalisation, for the same reason it carries its own status enum: it runs
    exactly when importing cast_handoff_parser has failed, so it cannot import it.
    This is the sync mechanism for that second copy — see TestStatusEnumParity."""

    CASES = (
        '**files_changed:** a.py\n**status:** DONE\n**blockers:** none\n',
        '- **files_changed:** a.py\n- **status:** DONE\n- **blockers:** none\n',
        '"files_changed": ["a.py"]\n"status": "DONE"\n"blockers": "none"\n',
        'Files changed: a.py\nStatus: DONE\nBlockers: none\n',
        'files_changed:\n- a.py\n- b.py\nstatus: DONE\nblockers: none\n',
        'files_changed:\n- a.py\n\nstatus: DONE\nblockers: none\n',
        'files_changed:\n- a.py\n- **status:** DONE\n- **blockers:** none\n',
        'files_changed:\nstatus: DONE\nblockers: none\n',
        'status: DONE\nblockers: none\n',
        '**files_changed:** a.py\n**status:** DONE\n**blockers:**\n',
        'files staged: a.py\nstatus: DONE\nblockers: none\n',
        '**files_changed:** a.py\n**status:** APPROVED\n**blockers:** none\n',
    )

    def test_both_copies_agree_on_every_shape(self):
        for body in self.CASES:
            text = '## Handoff\n' + body
            canonical = cast_handoff_parser.validate_handoff(text)['ok']
            inline = cast_subagent_stop._inline_validate_handoff(text)['ok']
            self.assertEqual(canonical, inline,
                             f'key-normalisation drift on:\n{body}\n'
                             f'canonical ok={canonical} inline ok={inline}')

    def test_required_field_lists_match(self):
        self.assertEqual(set(cast_handoff_parser._REQUIRED_FIELDS),
                         set(cast_subagent_stop._INLINE_REQUIRED_FIELDS))


if __name__ == '__main__':
    unittest.main()
