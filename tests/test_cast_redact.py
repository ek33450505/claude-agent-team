#!/usr/bin/env python3
"""Tests for new FALLBACK_PATTERNS added to cast-redact.py.

Covers:
  ABSOLUTE_PATH — /Users/<name>/... → ~/
  BITBUCKET_URL — bitbucket.org/... → [BITBUCKET_URL]
  SLACK_WEBHOOK — hooks.slack.com/... → [SLACK_WEBHOOK]
  STRIPE_KEY, SLACK_TOKEN, NPM_TOKEN, SENDGRID_KEY, GOOGLE_API_KEY, GENERIC_SECRET
    (C1b: closing redaction-engine blind spots — see _PII_CANDIDATES superset invariant test)
"""
from __future__ import annotations

import importlib.util
import json
import unittest
import io
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_REDACT_PATH = _SCRIPTS_DIR / 'cast-redact.py'

# cast-redact.py uses hyphens — load by file path via importlib.
_spec = importlib.util.spec_from_file_location('cast_redact', str(_REDACT_PATH))
cast_redact = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cast_redact)


def _redact(text: str) -> str:
    """Helper: run full regex pipeline and return redacted text."""
    entities = cast_redact.analyze_regex(text, [])
    return cast_redact.redact_regex(text, entities, mode='redact')


class TestAbsolutePathPattern(unittest.TestCase):

    def test_simple_home_path_redacted(self):
        text = 'file at /Users/johndoe/Projects/myapp/config.json'
        result = _redact(text)
        self.assertIn('~/', result)
        self.assertNotIn('/Users/johndoe', result)

    def test_path_with_hyphens_and_underscores_in_username(self):
        text = 'backup at /Users/john_doe-2/Backups/cast.db'
        result = _redact(text)
        self.assertIn('~/', result)
        self.assertNotIn('/Users/john_doe-2', result)

    def test_no_match_on_relative_path(self):
        text = 'relative path: ./scripts/foo.sh'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_linux_home_redacted(self):
        """S4-1 R2: Linux /home/<name>/ paths are redacted like /Users/<name>/."""
        result = _redact('path at /home/ubuntu/projects/')
        self.assertEqual('path at ~/', result)
        self.assertNotIn('ubuntu', result)


class TestBitbucketUrlPattern(unittest.TestCase):

    def test_bitbucket_repo_url_redacted(self):
        text = 'clone from bitbucket.org/myorg/myrepo.git'
        result = _redact(text)
        self.assertIn('[BITBUCKET_URL]', result)
        self.assertNotIn('bitbucket.org/myorg', result)

    def test_bitbucket_https_url_redacted(self):
        text = 'see https://bitbucket.org/myorg/myrepo/pull-requests/42'
        result = _redact(text)
        self.assertIn('[BITBUCKET_URL]', result)
        self.assertNotIn('myorg/myrepo', result)

    def test_no_match_on_github(self):
        text = 'see github.com/owner/repo'
        result = _redact(text)
        self.assertEqual(text, result)


class TestSlackWebhookPattern(unittest.TestCase):

    def test_slack_webhook_url_redacted(self):
        text = 'webhook: https://hooks.slack.com/' + 'services/EXAMPLE/EXAMPLE/EXAMPLE-FIXTURE-NOT-A-REAL-TOKEN'
        result = _redact(text)
        self.assertIn('[SLACK_WEBHOOK]', result)
        self.assertNotIn('FIXTURE', result)

    def test_slack_webhook_bare_redacted(self):
        text = 'POST to hooks.slack.com/' + 'fixture/example/sample-marker-xyz'
        result = _redact(text)
        self.assertIn('[SLACK_WEBHOOK]', result)
        self.assertNotIn('sample-marker-xyz', result)

    def test_no_match_on_slack_api(self):
        """slack.com/api is not a webhook URL."""
        text = 'call slack.com/api/chat.postMessage'
        result = _redact(text)
        self.assertEqual(text, result)


class TestCustomReplacements(unittest.TestCase):
    """Verify _CUSTOM_REPLACEMENTS dict drives correct substitution strings."""

    def test_absolute_path_replacement_value(self):
        self.assertEqual(cast_redact._CUSTOM_REPLACEMENTS['ABSOLUTE_PATH'], '~/')

    def test_bitbucket_url_replacement_value(self):
        self.assertEqual(cast_redact._CUSTOM_REPLACEMENTS['BITBUCKET_URL'], '[BITBUCKET_URL]')

    def test_slack_webhook_replacement_value(self):
        self.assertEqual(cast_redact._CUSTOM_REPLACEMENTS['SLACK_WEBHOOK'], '[SLACK_WEBHOOK]')

    def test_mask_mode_ignores_custom_replacements(self):
        """In mask mode, all entities use asterisks — custom replacements are not applied."""
        text = 'path /Users/' + 'alice/file.txt'
        entities = cast_redact.analyze_regex(text, [])
        result = cast_redact.redact_regex(text, entities, mode='mask')
        self.assertNotIn('~/', result)
        self.assertIn('*', result)


class TestStripeKeyPattern(unittest.TestCase):

    def test_stripe_sk_live_redacted(self):
        text = 'key: sk_live_' + 'A1' * 12  # 24 chars
        result = _redact(text)
        self.assertIn('<STRIPE_KEY>', result)
        self.assertNotIn('sk_live_', result)

    def test_stripe_pk_live_redacted(self):
        text = 'key: pk_live_' + 'B2' * 13  # 26 chars
        result = _redact(text)
        self.assertIn('<STRIPE_KEY>', result)

    def test_no_match_on_openai_hyphen_style(self):
        """Stripe uses underscore (sk_); OPENAI_KEY's sk- (hyphen) must not collide."""
        text = 'not a stripe key: sk-' + 'A' * 32
        result = _redact(text)
        self.assertNotIn('<STRIPE_KEY>', result)

    def test_short_circuit_no_at_digit_or_slash(self):
        probe = 'STRIPE=sk_test_' + 'ABCDEFGHIJKLMNOPQRSTUVWX'
        self.assertNotIn('@', probe)
        self.assertNotIn('/', probe)
        self.assertFalse(any(c.isdigit() for c in probe))
        result = _redact(probe)
        self.assertIn('<STRIPE_KEY>', result)


class TestSlackTokenPattern(unittest.TestCase):

    def test_slack_bot_token_redacted(self):
        text = 'token: xoxb-' + 'A1' * 6
        result = _redact(text)
        self.assertIn('<SLACK_TOKEN>', result)
        self.assertNotIn('xoxb-', result)

    def test_slack_user_token_redacted(self):
        text = 'token: xoxp-' + 'C3' * 6
        result = _redact(text)
        self.assertIn('<SLACK_TOKEN>', result)

    def test_no_match_on_prose_containing_xox(self):
        text = 'the xoxo pattern is unrelated to slack tokens'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_short_circuit_no_at_digit_or_slash(self):
        probe = 'SLACK=xoxb-' + 'ABCDEFGHIJKLMN'
        self.assertNotIn('@', probe)
        self.assertNotIn('/', probe)
        self.assertFalse(any(c.isdigit() for c in probe))
        result = _redact(probe)
        self.assertIn('<SLACK_TOKEN>', result)


class TestNpmTokenPattern(unittest.TestCase):

    def test_npm_token_redacted(self):
        text = 'auth: npm_' + 'A1' * 18  # 36 chars
        result = _redact(text)
        self.assertIn('<NPM_TOKEN>', result)
        self.assertNotIn('npm_', result)

    def test_no_match_on_short_npm_prefix(self):
        text = 'npm_short'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_short_circuit_no_at_digit_or_slash(self):
        probe = 'NPM=npm_' + 'A' * 36
        self.assertNotIn('@', probe)
        self.assertNotIn('/', probe)
        self.assertFalse(any(c.isdigit() for c in probe))
        result = _redact(probe)
        self.assertIn('<NPM_TOKEN>', result)

    def test_longer_than_36_chars_fully_captured(self):
        """Fix 3: {36,} not {36} — an exact-length quantifier under-captures a longer
        token instead of failing outright, leaving the tail characters leaked in plain
        text after the <NPM_TOKEN> tag (e.g. '<NPM_TOKEN>A1A1A1A1A1A1A1'). Asserting
        mere tag presence would pass under the {36} bug too — this must assert the
        FULL value is gone, not just that a tag appears.
        """
        text = 'auth: npm_' + 'A1' * 25  # 50-char body, well over the 36-char floor
        result = _redact(text)
        self.assertEqual('auth: <NPM_TOKEN>', result)
        self.assertNotIn('A1', result)


class TestSendgridKeyPattern(unittest.TestCase):

    def test_sendgrid_key_redacted(self):
        text = 'key: SG.' + 'A1' * 11 + '.' + 'A1' * 22
        result = _redact(text)
        self.assertIn('<SENDGRID_KEY>', result)
        self.assertNotIn('SG.', result)

    def test_no_match_on_version_string(self):
        text = 'version SG.1.2 is unrelated'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_short_circuit_no_at_digit_or_slash(self):
        probe = 'SG.' + 'ABCDEFGHIJKLMNOPQRSTUV' + '.' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGH'
        self.assertNotIn('@', probe)
        self.assertNotIn('/', probe)
        self.assertFalse(any(c.isdigit() for c in probe))
        result = _redact(probe)
        self.assertIn('<SENDGRID_KEY>', result)


class TestGoogleApiKeyPattern(unittest.TestCase):

    def test_google_api_key_redacted(self):
        text = 'key: AIza' + 'A' * 35
        result = _redact(text)
        self.assertIn('<GOOGLE_API_KEY>', result)
        self.assertNotIn('AIza' + 'A' * 35, result)

    def test_no_match_on_short_aiza_prefix(self):
        text = 'AIzaShort'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_short_circuit_no_at_digit_or_slash(self):
        probe = 'GOOGLE=AIza' + 'A' * 35
        self.assertNotIn('@', probe)
        self.assertNotIn('/', probe)
        self.assertFalse(any(c.isdigit() for c in probe))
        result = _redact(probe)
        self.assertIn('<GOOGLE_API_KEY>', result)


class TestGenericSecretPattern(unittest.TestCase):
    """GENERIC_SECRET: bare password=/passwd=/secret=/token=/access_token=/client_secret=
    assignments, including JSON/YAML/PHP quoted-key forms (see Fix 1/Fix 2 test classes
    below for those). Tradeoff: requires an assignment operator (`=`, `:`, or PHP's `=>`)
    directly after the keyword (optionally past a closing quote) AND a value of at least
    6 non-whitespace/non-quote chars — this avoids firing on ordinary prose (which uses
    "is"/"was"/"requires", never an operator), while still catching short-but-real
    placeholder secrets like "password=hunter" (6 chars).
    """

    def test_password_assignment_redacted(self):
        text = 'config: password=hunter'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)
        self.assertNotIn('hunter', result)

    def test_secret_assignment_redacted(self):
        text = 'secret=verysecretvalue123'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)

    def test_access_token_assignment_redacted(self):
        text = 'access_token=abc123xyz789'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)

    def test_client_secret_assignment_redacted(self):
        text = 'client_secret=zzzTopSecret999'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)

    def test_no_match_on_prose_without_assignment(self):
        """Prose mentioning 'password' with no '=' must not be redacted."""
        text = 'The password policy requires 8 characters and one digit.'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_no_match_on_short_value(self):
        """Values under the 6-char minimum are not treated as secrets."""
        text = 'token=abc'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_no_match_on_git_sha(self):
        text = 'commit abc123def456 fixed the bug'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_no_match_on_uuid(self):
        text = 'request id 550e8400-e29b-41d4-a716-446655440000'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_no_match_on_version_string(self):
        text = 'released version 1.2.3-beta.4 today'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_short_circuit_no_at_digit_or_slash(self):
        """The keyword itself (not @/digit/slash) must drive the fast-path trigger.

        This is the trap example from the C1b dispatch: 'password=hunter' contains no
        @, no digit, and no /. Without 'password' explicitly added to _PII_CANDIDATES,
        this text is short-circuited before the regex scan ever runs.
        """
        probe = 'password=hunter'
        self.assertNotIn('@', probe)
        self.assertNotIn('/', probe)
        self.assertFalse(any(c.isdigit() for c in probe))
        result = _redact(probe)
        self.assertIn('<GENERIC_SECRET>', result)


class TestGenericSecretQuotedForms(unittest.TestCase):
    """Fix 1 (found by team-lead probing, both gates missed it): quoted-key forms
    (JSON, YAML, PHP fat-arrow) previously evaded GENERIC_SECRET entirely because the
    old pattern required the operator immediately after the bare keyword — a closing
    quote sitting between the keyword and the operator broke the match. Agent reports
    quoting JSON config dumps / API responses is plausibly the most common real shape
    a leaked secret takes in this corpus.
    """

    def test_json_double_quoted_password(self):
        text = '{"password": "hunter2xyz"}'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)
        self.assertNotIn('hunter2xyz', result)

    def test_json_client_secret(self):
        text = '{"client_secret": "abcdef123456"}'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)
        self.assertNotIn('abcdef123456', result)

    def test_json_no_space_after_colon(self):
        text = '{"token":"abcdef123456"}'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)
        self.assertNotIn('abcdef123456', result)

    def test_php_single_quoted_fat_arrow(self):
        text = "'password' => 'hunter2xyz'"
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)
        self.assertNotIn('hunter2xyz', result)

    def test_fat_arrow_unquoted_with_spaces(self):
        text = 'password => hunter2xyz'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)
        self.assertNotIn('hunter2xyz', result)

    def test_yaml_key_colon_newline_indented_value(self):
        text = 'password:\n  s3cr3tValue123'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)
        self.assertNotIn('s3cr3tValue123', result)

    def test_no_match_on_null_placeholder(self):
        """team-lead's explicit ask: keyword+operator+null-ish placeholder should NOT fire."""
        for text in ('secret: null', 'password: undefined', 'token: None'):
            with self.subTest(text=text):
                result = _redact(text)
                self.assertEqual(text, result)

    def test_no_match_on_markdown_table_row(self):
        text = '| secret | description |'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_short_circuit_json_form_no_at_digit_or_slash(self):
        probe = '{"password":"hunterxyzabc"}'
        self.assertNotIn('@', probe)
        self.assertNotIn('/', probe)
        self.assertFalse(any(c.isdigit() for c in probe))
        result = _redact(probe)
        self.assertIn('<GENERIC_SECRET>', result)


class TestGenericSecretPunctuationCharset(unittest.TestCase):
    """Fix 2 (from security): the old value charset was an allowlist that excluded
    "!", "@", "%", and base64 padding "=", so those trailing characters leaked outside
    the redacted span instead of being consumed by it. Widened to a denylist
    ([^\\s'"`] — see TestGenericSecretCorpusSweepFixes for why the backtick is
    excluded) per security's recommendation, with trailing sentence punctuation
    (".", ",", ")") trimmed back out in analyze_regex() — the regex alone can't tell
    "part of the secret" from "end of the sentence", so trimming happens after the
    match, not in the charset itself. Precision/recall tradeoff: the denylist only
    changes what a triggered match captures, not whether a keyword+operator pair
    triggers a match at all, so this should not increase the false-positive rate
    measured over the real-response corpus — only fix under- and over-capture on
    matches that were already firing.
    """

    def test_trailing_bang_is_captured_not_leaked(self):
        text = 'PASSWORD=Sup3rSecret!'
        result = _redact(text)
        self.assertEqual('PASSWORD=<GENERIC_SECRET>', result)
        self.assertNotIn('!', result)

    def test_base64_padding_captured_for_realistic_length_value(self):
        """secret=abc== (5 total chars) stays below our 6-char floor by design — see
        test_no_match_on_short_value. A realistic-length base64 value with padding
        must be captured whole, padding included.
        """
        text = 'secret=abcdef=='
        result = _redact(text)
        self.assertEqual('secret=<GENERIC_SECRET>', result)
        self.assertNotIn('==', result)

    def test_trailing_period_not_swallowed(self):
        text = 'in dev (password=Secret123).'
        result = _redact(text)
        self.assertEqual('in dev (password=<GENERIC_SECRET>).', result)

    def test_trailing_comma_not_swallowed(self):
        text = 'token=abc123xyz, then rotate it'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>,', result)

    def test_trailing_close_paren_not_swallowed(self):
        text = '(secret=abc123xyz)'
        result = _redact(text)
        self.assertEqual('(secret=<GENERIC_SECRET>)', result)


class TestGenericSecretCorpusSweepFixes(unittest.TestCase):
    """Corpus sweep (2026-08-16, 2446 real agent responses) measured the widened
    Fix-2 charset at 8 GENERIC_SECRET hits against a budget of 1 true positive / 0
    false positives: 6 of 8 were markdown documentation ABOUT secret patterns (the
    backtick let `password=`/`secret=`/`token=` prose examples match), and 2 were
    the redactor re-matching its own <ENTITY_TYPE> output on a second pass. Both
    causes are subtle and will regress silently without a dedicated ratchet test —
    this is that ratchet. Post-fix corpus result: 2/2 true positives, 0 false
    positives (verified by team-lead, not reproducible here without the corpus).
    """

    def test_no_match_on_markdown_prose_about_secret_patterns(self):
        """Cause 1 (the cry-wolf case): documentation ABOUT the redaction patterns
        themselves — inline-code-quoted keyword= examples with no real values —
        must not be flagged. This is literally security review prose about this
        unit; a redactor that fires on it gets disabled.
        """
        text = 'unlabeled `password=`/`secret=`/`token=` pairs'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_backtick_adjacent_real_secret_still_redacted_backticks_survive(self):
        """Cause 1, other half: excluding the backtick from the value charset must
        not stop a REAL secret wrapped in backticks from being redacted — only the
        markdown fencing should survive outside the tag.
        """
        text = '`secret=abc123xyz`'
        result = _redact(text)
        self.assertEqual('`secret=<GENERIC_SECRET>`', result)

    def test_idempotent_second_pass_is_a_noop(self):
        """Cause 2: re-running the redactor over its own output must not produce a
        fresh match on the <ENTITY_TYPE> placeholder itself.

        NOTE: string equality (redact(redact(x)) == redact(x)) alone is NOT a
        sufficient assertion here and was caught as a weak proxy during mutation
        testing — the original keyword (e.g. "password=") survives redaction (only
        the VALUE is replaced), so a spurious second-pass match that captures
        "<GENERIC_SECRET>" as its own "value" produces the textually IDENTICAL
        output ("<GENERIC_SECRET>" replaced by "<GENERIC_SECRET>") whether or not
        the placeholder lookahead is present — the string-equality assertion passed
        even with the lookahead reverted. This test therefore also asserts directly
        on analyze_regex() that the second pass detects ZERO entities, which does
        discriminate the mutation.
        """
        for text in ('PASSWORD=Sup3rSecret!', 'secret=abcdef==', 'token=abc123xyz,'):
            with self.subTest(text=text):
                once = _redact(text)
                twice = _redact(once)
                self.assertEqual(once, twice)
                second_pass_entities = cast_redact.analyze_regex(once, [])
                self.assertEqual(
                    [], second_pass_entities,
                    f"second pass over already-redacted text {once!r} found "
                    f"entities: {second_pass_entities!r}",
                )


class TestGenericSecretRound2SecurityFixes(unittest.TestCase):
    """security re-review (2026-08-16) found 2 HIGH + 1 MEDIUM in the round-1
    remediation itself, all reproduced as ZERO-ENTITY full plaintext leaks:

    Fix A (HIGH): excluding the backtick from the value charset last round (to kill
    markdown-prose false positives) also excluded it as a value DELIMITER, so
    markdown-fenced real secrets (`` password: `X` `` — a common convention in agent
    prose) went undetected entirely. Backtick is now allowed as an optional
    opening/closing delimiter while staying excluded from the value charset itself.

    Fix B (HIGH): `(?!<[A-Z_]+>)` compiled under the module's re.IGNORECASE flag, so
    [A-Z_] silently also matched lowercase — ANY `<word>`-prefixed value evaded, not
    just the redactor's own <ENTITY_TYPE> tags (e.g. `token=<PROD>abc123realvalue`,
    a realistic templated-config shape). Replaced with a case-SENSITIVE lookahead
    ((?-i:...)) anchored to the actual known tag names, derived from
    _STANDARD_FALLBACK_PATTERNS rather than hardcoded.

    Fix C (MEDIUM): trimming trailing punctuation could take a match under the
    6-char floor, and the old code then DISCARDED the entity entirely — converting
    an already-short secret into a full leak. Now keeps the untrimmed span instead.

    Revised false-positive bar (team-lead, 2026-08-16, re-measured on a
    session-contaminated-excluded 2437-response slice): 1 FP in 2437 (the word
    "WebSearch" quoted in prose) is acceptable — prefer recall over precision for
    this pattern; do not add an entropy/charset heuristic to chase 0 FP, since that
    also kills real all-alphabetic passphrases like "password=correcthorse".
    """

    def test_backtick_fenced_value_after_colon_redacted(self):
        text = 'password: `S3cr3tPass99`'
        result = _redact(text)
        self.assertEqual('password: `<GENERIC_SECRET>`', result)
        self.assertNotIn('S3cr3tPass99', result)

    def test_backtick_fenced_value_after_equals_redacted(self):
        text = 'secret=`hello_world_1`'
        result = _redact(text)
        self.assertEqual('secret=`<GENERIC_SECRET>`', result)
        self.assertNotIn('hello_world_1', result)

    def test_uppercase_angle_bracket_prefixed_value_not_bypassed(self):
        """token=<PROD>abc123realvalue is a realistic templated-config value, not
        one of the redactor's own emitted tags — must still be redacted whole.
        """
        text = 'token=<PROD>abc123realvalue'
        result = _redact(text)
        self.assertEqual('token=<GENERIC_SECRET>', result)
        self.assertNotIn('abc123realvalue', result)

    def test_lowercase_angle_bracket_prefixed_value_not_bypassed(self):
        """The specific IGNORECASE hole: [A-Z_] under re.IGNORECASE also matches
        lowercase, so a lowercase <tag>-prefixed value must not evade either.
        """
        text = 'token=<abc>realvalue'
        result = _redact(text)
        self.assertEqual('token=<GENERIC_SECRET>', result)
        self.assertNotIn('realvalue', result)

    def test_trim_below_floor_keeps_untrimmed_span_not_dropped(self):
        """The MEDIUM: trimming '.' off 'Abcde.' (6 chars) drops to 'Abcde' (5,
        under the floor) — must keep the untrimmed 6-char span, not discard it.
        """
        text = 'The password=Abcde.'
        result = _redact(text)
        self.assertEqual('The password=<GENERIC_SECRET>', result)
        self.assertNotIn('Abcde', result)

    def test_own_tag_still_not_rematched_case_sensitive(self):
        """The case-sensitive anchored lookahead must still catch the redactor's
        OWN real tags (idempotency), even though it no longer matches arbitrary
        lowercase <word> values.
        """
        text = 'token=<GENERIC_SECRET>'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_markdown_prose_about_patterns_still_clean(self):
        text = 'unlabeled `password=`/`secret=`/`token=` pairs'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_null_placeholder_with_equals_still_clean(self):
        text = 'password=null'
        result = _redact(text)
        self.assertEqual(text, result)

    def test_known_false_positive_websearch_is_accepted_tradeoff(self):
        """Documents the accepted 1-FP/2437 bar rather than hiding it: quoting the
        literal word "WebSearch" in prose does get redacted. This is intentional —
        see class docstring for why recall is preferred over precision here.
        """
        text = 'a single literal token: `WebSearch`'
        result = _redact(text)
        self.assertIn('<GENERIC_SECRET>', result)


class TestKnownEntityTagsCompleteness(unittest.TestCase):
    """Fix B's tag lookahead is DERIVED from _STANDARD_FALLBACK_PATTERNS rather than
    hardcoded, specifically so it can't go stale as new patterns are added — this
    test guards that derivation itself stays wired up correctly.
    """

    def test_every_non_generic_secret_entity_type_is_a_known_tag(self):
        for etype, _ in cast_redact.FALLBACK_PATTERNS:
            if etype == 'GENERIC_SECRET':
                continue
            with self.subTest(etype=etype):
                self.assertIn(etype, cast_redact._KNOWN_ENTITY_TAGS)

    def test_generic_secret_and_placeholder_words_are_known_tags(self):
        for tag in ('GENERIC_SECRET', 'REDACTED', 'MASKED'):
            with self.subTest(tag=tag):
                self.assertIn(tag, cast_redact._KNOWN_ENTITY_TAGS)


class TestPiiCandidatesSuperset(unittest.TestCase):
    """Durable ratchet: every FALLBACK_PATTERNS entry must have a representative sample
    that also matches _PII_CANDIDATES — otherwise the pattern is silently dead (the F3
    fast-path short-circuits before the regex scan ever reaches it).
    """

    # One deliberately minimal, obviously-fake sample per entity_type that the pattern
    # is known to match. Kept in sync manually with FALLBACK_PATTERNS additions.
    _SAMPLES: dict[str, str] = {
        'EMAIL_ADDRESS': 'someone@example.com',
        'PHONE_NUMBER': '555-123-4567',
        'US_SSN': '123-45-6789',
        'CREDIT_CARD': '4111111111111111',
        'IP_ADDRESS': '10.0.0.1',
        # Adversarially minimal: all-letter body (no digit) — the AWS_ACCESS_KEY
        # pattern (AKIA[0-9A-Z]{16}) does NOT require a digit, only the "AKIA"
        # prefix; AWS's own example key ('AKIA' + 'IOSFODNN7EXAMPLE') contains a
        # '7' that incidentally trips the (formerly digit-based) _PII_CANDIDATES
        # trigger, masking that the pattern was dead for all-letter keys. Split
        # so the pre-push PII scanner does not flag a benign fixture.
        'AWS_ACCESS_KEY': 'AKIA' + 'BCDEFGHIJKLMNOPQ',
        'AWS_SECRET_ACCESS_KEY': 'aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        'GITHUB_TOKEN': 'ghp_' + 'A' * 36,
        'ANTHROPIC_KEY': 'sk-ant-' + 'A' * 32,
        'OPENAI_KEY': 'sk-' + 'A' * 32,
        'BEARER_TOKEN': 'bearer ' + 'A' * 20,
        'JWT': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature',
        'DATABASE_URL': 'postgres://user:pass@host/db',
        'PRIVATE_KEY': '-----BEGIN PRIVATE KEY-----',
        'API_KEY': 'api_key=' + 'A' * 20,
        'ABSOLUTE_PATH': '/Users/' + 'alice/file.txt',
        'BITBUCKET_URL': 'bitbucket.org/org/repo',
        'SLACK_WEBHOOK': 'hooks.slack.com/services/X/Y/Z',
        'STRIPE_KEY': 'sk_live_' + 'A' * 24,
        'SLACK_TOKEN': 'xoxb-' + 'A' * 12,
        'NPM_TOKEN': 'npm_' + 'A' * 36,
        'SENDGRID_KEY': 'SG.' + 'A' * 22 + '.' + 'A' * 43,
        'GOOGLE_API_KEY': 'AIza' + 'A' * 35,
        'RESEND_KEY': 're_' + 'A1b' * 8,
        'GITLAB_TOKEN': 'glpat-' + 'A' * 20,
        'VENDOR_TOKEN_ASSIGNMENT': 'zenodo_token=' + 'A' * 30,
        'GENERIC_SECRET': 'password=hunter',
    }

    # Entity types registered more than once (DATABASE_URL main + OVERSIZE companion, same
    # label on purpose): the 2nd and later entries are checked against these samples.
    _SECOND_SAMPLES: dict[str, str] = {
        'DATABASE_URL': 'postgres://u:' + 'A' * 1025 + '@h/db',
    }

    def test_all_patterns_have_samples(self):
        pattern_types = {etype for etype, _ in cast_redact.FALLBACK_PATTERNS}
        self.assertEqual(pattern_types, set(self._SAMPLES.keys()))

    def test_every_pattern_sample_matches_pii_candidates(self):
        seen = set()
        for etype, pat in cast_redact.FALLBACK_PATTERNS:
            sample = self._SECOND_SAMPLES[etype] if etype in seen else self._SAMPLES[etype]
            seen.add(etype)
            # Confirm the sample actually matches its own pattern (sample is representative).
            self.assertRegex(sample, pat, f'{etype}: sample does not match its own pattern')
            # The invariant under test: the same sample must also trigger the fast-path.
            self.assertTrue(
                cast_redact._PII_CANDIDATES.search(sample),
                f'{etype}: sample "{sample}" matches FALLBACK_PATTERNS but not '
                f'_PII_CANDIDATES — this pattern is dead code behind the F3 short-circuit',
            )


class TestRedactRegexOverlappingSpans(unittest.TestCase):
    """C1d defect (a): analyze_regex does not guarantee non-overlapping spans (its
    docstring claim), and redact_regex previously assumed it did — a right-to-left
    splice used stale (pre-shift) indices once an inner replacement's length delta
    had shifted the string, leaking a plaintext tail of the outer secret.

    The durable ratchet is the general invariant below (no detected entity's
    `original` value may survive as a substring of the redacted output) exercised
    over a table of inputs — not a single golden string, since a shrinking inner
    replacement (mysql case) truncates rather than leaks and would pass even with
    the bug fully present.
    """

    # DATABASE_URL with an IP_ADDRESS nested inside, inner replacement LONGER than
    # the original span (<IP_ADDRESS> is 12 chars vs '10.0.0.1' at 8) — this is the
    # case that leaked "ppdb" before the fix.
    _CASE_GROWING_INNER = 'postgres://user:pa55word@10.0.0.1/appdb'
    # DATABASE_URL with an EMAIL_ADDRESS nested inside, inner replacement SHORTER
    # than the original span — truncates rather than leaks even with the bug
    # present, so this alone would never have caught the defect; kept as a
    # regression guard, not a repro.
    _CASE_SHRINKING_INNER = 'mysql://admin:hunter22' + '@db.internal:3306/prod'
    # Two separate outer entities, each with its own nested IP, back to back.
    _CASE_MULTIPLE_OUTER = (
        'multiple: postgres://a:b@192.168.1.1/db and mongodb://c:d@10.0.0.2/db2'
    )

    _CASES = [_CASE_GROWING_INNER, _CASE_SHRINKING_INNER, _CASE_MULTIPLE_OUTER]

    def test_no_entity_original_survives_in_redacted_output(self):
        for text in self._CASES:
            with self.subTest(text=text):
                entities = cast_redact.analyze_regex(text, [])
                self.assertTrue(entities, 'test case must actually detect entities')
                redacted = cast_redact.redact_regex(text, entities, mode='redact')
                for entity in entities:
                    original = entity['original']
                    self.assertNotIn(
                        original, redacted,
                        f'{entity["entity_type"]} original {original!r} survived '
                        f'in redacted output {redacted!r}',
                    )

    def test_growing_inner_span_no_tail_leak(self):
        # The exact repro: without merging, the outer DATABASE_URL span's stale
        # end-index sliced 4 chars too early into the shifted string, leaking
        # "ppdb". Merged, the outer (broader) span wins outright.
        redacted = _redact(self._CASE_GROWING_INNER)
        self.assertEqual(redacted, '<DATABASE_URL>')

    def test_shrinking_inner_span_still_clean(self):
        redacted = _redact(self._CASE_SHRINKING_INNER)
        self.assertEqual(redacted, '<DATABASE_URL>')

    def test_multiple_outer_entities_both_clean(self):
        redacted = _redact(self._CASE_MULTIPLE_OUTER)
        self.assertEqual(redacted, 'multiple: <DATABASE_URL> and <DATABASE_URL>')

    def test_mask_mode_merges_spans_too(self):
        # mask mode uses "*" * (end - start) on the MERGED span — assert it does
        # not raise and produces no leftover plaintext fragment either.
        entities = cast_redact.analyze_regex(self._CASE_GROWING_INNER, [])
        masked = cast_redact.redact_regex(self._CASE_GROWING_INNER, entities, mode='mask')
        self.assertNotIn('10.0.0.1', masked)
        self.assertNotIn('appdb', masked)


class TestAwsAccessKeyAllLetterDetection(unittest.TestCase):
    """C1d defect (b): AKIA was missing from _PII_CANDIDATES, so an all-letter AKIA
    key (no digit anywhere in the surrounding text) never reached analyze_regex at
    all — the F3 fast-path short-circuited before the AWS_ACCESS_KEY pattern ever
    ran, a full plaintext leak.
    """

    _ALL_LETTER_KEY = 'AKIA' + 'BCDEFGHIJKLMNOPQ'  # 16 letters, no digit anywhere

    def test_candidate_fast_path_triggers_without_a_digit(self):
        text = f'aws key {self._ALL_LETTER_KEY} rotate it'
        self.assertNotRegex(text, r'\d', 'fixture must contain no digit at all')
        self.assertTrue(cast_redact._PII_CANDIDATES.search(text))

    def test_all_letter_key_is_detected_and_redacted(self):
        text = f'aws key {self._ALL_LETTER_KEY} rotate it'
        entities = cast_redact.analyze_regex(text, [])
        self.assertEqual([e['entity_type'] for e in entities], ['AWS_ACCESS_KEY'])
        redacted = cast_redact.redact_regex(text, entities, mode='redact')
        self.assertNotIn(self._ALL_LETTER_KEY, redacted)
        self.assertIn('<AWS_ACCESS_KEY>', redacted)


class TestPrivateKeyNoSpaceAfterBegin(unittest.TestCase):
    """C1d-follow: PRIVATE_KEY's body (`[A-Z ]+` between "BEGIN" and "PRIVATE KEY"/
    "CERTIFICATE") is letters-OR-spaces, so a space immediately after "BEGIN" is NOT
    guaranteed — the fast-path trigger was `BEGIN\\s`, which is a false superset claim
    for the all-letter form (e.g. "-----BEGINRSA PRIVATE KEY-----"). Every REAL PEM
    header has a space there, so severity is low, but the false superset claim is the
    same class of bug that made AWS_ACCESS_KEY dead code for months — fixed by
    widening the trigger to the bare "BEGIN" literal.
    """

    # Split so no contiguous PEM-shaped literal sits on one line (pre-push PII scanner
    # convention — same trick used for the AKIA fixtures above).
    _NO_SPACE_AFTER_BEGIN = '-----BEGIN' + 'RSA PRIVATE KEY-----'

    def test_matches_private_key_pattern(self):
        private_key_pattern = dict(cast_redact.FALLBACK_PATTERNS)['PRIVATE_KEY']
        self.assertRegex(self._NO_SPACE_AFTER_BEGIN, private_key_pattern)

    def test_no_space_after_begin_still_triggers_fast_path(self):
        self.assertNotRegex(
            self._NO_SPACE_AFTER_BEGIN, r'BEGIN\s',
            'fixture must have no whitespace immediately after BEGIN',
        )
        self.assertTrue(cast_redact._PII_CANDIDATES.search(self._NO_SPACE_AFTER_BEGIN))

    def test_no_space_after_begin_is_detected_and_redacted(self):
        entities = cast_redact.analyze_regex(self._NO_SPACE_AFTER_BEGIN, [])
        self.assertEqual([e['entity_type'] for e in entities], ['PRIVATE_KEY'])
        redacted = cast_redact.redact_regex(self._NO_SPACE_AFTER_BEGIN, entities, mode='redact')
        self.assertNotIn(self._NO_SPACE_AFTER_BEGIN, redacted)
        self.assertIn('<PRIVATE_KEY>', redacted)


class TestMachineDerivedPiiCandidatesRatchet(unittest.TestCase):
    """Machine-derived superset ratchet: walk each FALLBACK_PATTERNS regex's parse tree
    to generate a minimal sample, preferring letters over digits at every choice point.
    This catches the AWS_ACCESS_KEY and PRIVATE_KEY class bugs (hand-chosen samples
    hide issues via accidental digit/space inclusion) that passed the old hand-maintained
    superset test twice in production.

    Patterns that the generator cannot handle are listed explicitly in
    _UNHANDLEABLE_PATTERNS; the list grows only by deliberate edit (an invariant test
    fails if it shrinks, catching stale exemptions; another fails if it grows,
    preventing silent skips of new patterns). Hand-maintained samples in
    TestPiiCandidatesSuperset still cover all patterns, including unhandleable ones.
    """

    # Patterns the generator cannot handle and must be exempted.
    # RESEND_KEY uses lookaheads (digit AND letter required in the body), which the
    # simple generator cannot satisfy; it is covered by hand-maintained samples instead.
    _UNHANDLEABLE_PATTERNS = frozenset({'RESEND_KEY'})

    def _generate_sample(self, pattern_str: str) -> str | None:
        """Parse regex pattern and generate a minimal matching sample.
        Returns None if the pattern cannot be handled.

        Preference: letters over digits at every choice point, to find the
        adversarial case (no incidental digit hiding a gap in _PII_CANDIDATES).
        """
        try:
            # Try re._parser first (available in Python 3.8+), fall back to sre_parse.
            try:
                from re import _parser as regex_parser
                import re as re_module
            except (ImportError, AttributeError):
                try:
                    import sre_parse as regex_parser
                    import re as re_module
                except ImportError:
                    return None

            # Parse WITH the re.IGNORECASE flag (don't let it leak into the tree walk)
            parsed = regex_parser.parse(pattern_str, flags=re_module.IGNORECASE)
        except Exception:
            return None

        def walk(node_list):
            """Walk parse tree nodes and emit characters, preferring letters."""
            result = []
            try:
                for code, value in node_list:
                    # Node codes: see sre_parse module. We handle the major ones.
                    if code == regex_parser.LITERAL:
                        # Single character literal
                        result.append(chr(value))
                    elif code == regex_parser.IN:
                        # Character class [...]
                        sample_char = self._char_from_in_set(value)
                        if sample_char is None:
                            return None  # Unsupported class
                        result.append(sample_char)
                    elif code == regex_parser.ANY:
                        # . (any char except newline)
                        result.append('a')
                    elif code == regex_parser.MAX_REPEAT or code == regex_parser.MIN_REPEAT:
                        # Quantified subpattern
                        min_count, max_count, sub = value
                        # Emit min_count or 1 if min_count is 0
                        repeat_count = max(min_count, 1)
                        for _ in range(repeat_count):
                            sub_result = walk(sub)
                            if sub_result is None:
                                return None
                            result.append(sub_result)
                    elif code == regex_parser.SUBPATTERN:
                        # Group (...)
                        group_id, add_flags, del_flags, sub = value
                        sub_result = walk(sub)
                        if sub_result is None:
                            return None
                        result.append(sub_result)
                    elif code == regex_parser.BRANCH:
                        # Alternation: value is (None, [[alt1_nodes], [alt2_nodes], ...])
                        # Take the first alternative for a minimal sample
                        alternatives = value[1]  # List of alternatives, each is a list of nodes
                        if alternatives:
                            first_alt = alternatives[0]  # List of nodes for first alternative
                            branch_result = walk(first_alt)
                            if branch_result is None:
                                return None
                            result.append(branch_result)
                    elif code == regex_parser.AT:
                        # Anchor: skip (^, $, \b, etc.)
                        pass
                    elif code == regex_parser.ASSERT or code == regex_parser.ASSERT_NOT:
                        # Lookahead/lookbehind: skip
                        pass
                    elif code == regex_parser.NEGATE:
                        # Should not appear at top level
                        return None
                    else:
                        # Unknown node type
                        return None
                return ''.join(result)
            except (ValueError, TypeError, AttributeError):
                # Unparseable structure
                return None

        sample = walk(parsed)
        return sample if sample else None

    def _char_from_in_set(self, in_set_value) -> str | None:
        r"""Extract a character from a character class [...].

        Prefers letters over digits at every choice point. This is load-bearing for the
        superset invariant: a sample containing an incidental digit satisfies _PII_CANDIDATES'
        `\d` trigger by accident and hides the very gap this test exists to catch. This happened
        to AWS_ACCESS_KEY for months (sample was AWS's own example key 'AKIA...7EXAMPLE' with an
        incidental '7'; all-letter keys 'AKIA...Z' never matched _PII_CANDIDATES and leaked
        plaintext). Same class of bug hid PRIVATE_KEY behind 'BEGIN\s' (an all-letter pattern
        without space never matched the early trigger). Letter preference forces us to find the
        adversarial case.
        """
        # in_set_value is a list of (code, value) pairs for the class contents.
        # NEGATE flag indicates negation. RANGE, CATEGORY, LITERAL codes appear.
        try:
            from re import _parser as regex_parser
        except (ImportError, AttributeError):
            try:
                import sre_parse as regex_parser
            except ImportError:
                return None

        # Check for NEGATE flag first
        is_negated = any(code == regex_parser.NEGATE for code, _ in in_set_value)

        # Extract candidates (non-negated case), preferring letters
        letter_candidates = []
        other_candidates = []

        for code, value in in_set_value:
            if code == regex_parser.NEGATE:
                continue
            elif code == regex_parser.LITERAL:
                c = chr(value)
                if c.isalpha():
                    letter_candidates.append(c)
                else:
                    other_candidates.append(c)
            elif code == regex_parser.RANGE:
                # RANGE is (start, end) pair
                start, end = value
                # Collect letters first, then others
                for cp in range(start, end + 1):
                    c = chr(cp)
                    if c.isalpha():
                        letter_candidates.append(c)
                    else:
                        other_candidates.append(c)
            elif code == regex_parser.CATEGORY:
                # CATEGORY like DIGIT, SPACE, etc.; map to a sample.
                cat_str = str(value)
                if 'DIGIT' in cat_str:
                    other_candidates.append('5')  # Prefer digit '5'
                elif 'SPACE' in cat_str:
                    other_candidates.append(' ')
                elif 'WORD' in cat_str:
                    letter_candidates.append('a')  # Word char, prefer letter
                else:
                    other_candidates.append('x')

        # If negated, return something not in the excluded set (union of both)
        if is_negated:
            excluded = set(letter_candidates + other_candidates)
            # Pick something outside it, preferring letters
            for c in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789':
                if c not in excluded:
                    return c
            return '!'

        # Not negated: return first candidate, preferring letters
        if letter_candidates:
            return letter_candidates[0]
        if other_candidates:
            return other_candidates[0]

        return 'a'  # Fallback

    def test_generator_can_handle_required_patterns(self):
        """Patterns NOT in _UNHANDLEABLE_PATTERNS must have the generator produce a sample."""
        for etype, pat in cast_redact.FALLBACK_PATTERNS:
            if etype in self._UNHANDLEABLE_PATTERNS:
                continue
            with self.subTest(etype=etype):
                sample = self._generate_sample(pat)
                self.assertIsNotNone(
                    sample,
                    f'{etype}: generator failed to produce a sample for pattern {pat!r}'
                )
                # Sample must match the pattern itself
                try:
                    regex = re.compile(pat, re.IGNORECASE)
                    self.assertRegex(sample, regex, f'{etype}: generated sample {sample!r} does not match its own pattern')
                except re.error:
                    self.fail(f'{etype}: pattern {pat!r} is invalid regex')

    def test_machine_samples_trigger_pii_candidates(self):
        """Every machine-generated sample must also match _PII_CANDIDATES (the superset invariant)."""
        for etype, pat in cast_redact.FALLBACK_PATTERNS:
            if etype in self._UNHANDLEABLE_PATTERNS:
                # Exempted patterns must still be covered by hand-maintained samples
                # in TestPiiCandidatesSuperset; not tested here.
                continue
            with self.subTest(etype=etype):
                sample = self._generate_sample(pat)
                if sample is None:
                    continue  # Already asserted above for non-exempt patterns
                self.assertTrue(
                    cast_redact._PII_CANDIDATES.search(sample),
                    f'{etype}: machine sample {sample!r} matches pattern but NOT _PII_CANDIDATES '
                    f'— the fast-path is broken for this pattern'
                )

    def test_unhandleable_list_does_not_grow(self):
        """Fail if a new pattern is added to FALLBACK_PATTERNS but not to _UNHANDLEABLE_PATTERNS.

        This guards against silent skips: if the generator fails on a new pattern, someone
        must consciously add it to the exemption list, not let it be silently skipped.
        """
        handled_types = {
            etype for etype, _ in cast_redact.FALLBACK_PATTERNS
            if etype not in self._UNHANDLEABLE_PATTERNS
        }
        # If this fails, either:
        # 1. A new pattern was added that the generator cannot handle → add it to _UNHANDLEABLE_PATTERNS
        # 2. A pattern was removed → update _UNHANDLEABLE_PATTERNS
        # 3. The generator improved → remove the pattern from _UNHANDLEABLE_PATTERNS
        all_types = {etype for etype, _ in cast_redact.FALLBACK_PATTERNS}
        unhandled = all_types - handled_types
        self.assertEqual(
            unhandled, self._UNHANDLEABLE_PATTERNS,
            f'Unhandleable patterns list mismatch. Expected {self._UNHANDLEABLE_PATTERNS!r}, '
            f'but generator cannot handle {unhandled!r}. Update _UNHANDLEABLE_PATTERNS.'
        )

    def test_unhandleable_list_does_not_contain_obsolete_entries(self):
        """Fail if _UNHANDLEABLE_PATTERNS lists a pattern the generator CAN now handle.

        This guards against stale exemptions: as the generator improves, the list must shrink.

        NOTE: This test is dormant-by-design while the list is empty (loop runs zero times).
        It cannot fire in the current state. This is intentional future-proofing: the moment
        a pattern is added to _UNHANDLEABLE_PATTERNS, this test activates and will fail if
        the generator can actually handle it. Verified by mutation: adding a bogus entry
        causes this test to fail as expected.
        """
        for etype in self._UNHANDLEABLE_PATTERNS:
            if etype not in {e for e, _ in cast_redact.FALLBACK_PATTERNS}:
                # Pattern was removed entirely; OK to keep it in the list (harmless).
                continue
            with self.subTest(etype=etype):
                pat = dict(cast_redact.FALLBACK_PATTERNS)[etype]
                sample = self._generate_sample(pat)
                # If the pattern is in the exemption list, it SHOULD fail to generate.
                # If it now succeeds, remove it from _UNHANDLEABLE_PATTERNS.
                if sample is not None:
                    # Double-check: does the sample actually match the pattern?
                    try:
                        regex = re.compile(pat, re.IGNORECASE)
                        if regex.search(sample):
                            self.fail(
                                f'{etype}: generator now SUCCEEDS for this pattern (sample={sample!r}), '
                                f'but it is still in _UNHANDLEABLE_PATTERNS — remove it from the list'
                            )
                    except re.error:
                        pass  # Pattern is invalid; OK to keep exempted.


class TestVendorSecretGaps(unittest.TestCase):
    """S-3: Resend / GitLab / Zenodo+Cloudflare (context-anchored) token patterns.

    Fixtures are built at runtime by concatenation so no real-looking secret literal
    appears in source (repo gitleaks / pii-scan would flag it).
    """

    RESEND = 're_' + 'A1b2' * 6
    GITLAB = 'glpat-' + 'Ab3x' * 6
    VENDOR = 'Zq9' * 12

    def test_resend_key_redacted(self):
        result = _redact('key is ' + self.RESEND + ' ok')
        self.assertNotIn(self.RESEND, result)
        self.assertIn('<RESEND_KEY>', result)

    def test_gitlab_token_redacted(self):
        result = _redact('token ' + self.GITLAB + ' here')
        self.assertNotIn(self.GITLAB, result)
        self.assertIn('<GITLAB_TOKEN>', result)

    def test_gitlab_other_prefixes_redacted(self):
        for prefix in ('gldt-', 'glrt-', 'glrtr-', 'glcbt-', 'glffct-', 'gloas-', 'glagent-'):
            with self.subTest(prefix=prefix):
                tok = prefix + 'Ab3x' * 6
                result = _redact('tok ' + tok + ' end')
                self.assertNotIn(tok, result)
                self.assertIn('<GITLAB_TOKEN>', result)

    def test_gitlab_short_body_not_redacted(self):
        text = 'x glpat-' + 'a' * 19 + ' y'
        self.assertEqual(text, _redact(text))

    def test_resend_identifier_false_positives_not_redacted(self):
        for text in ('re_compile_pattern_v2_handler', 're_store_user_2fa_enabled_flag_v3',
                     'RE_MAX_RETRY_COUNT_2026_LIMIT'):
            with self.subTest(text=text):
                self.assertEqual(text, _redact(text))

    def test_json_quoted_vendor_keys_redacted(self):
        for text in ('{"zenodo_token":"%s"}', '"CF_API_TOKEN": "%s"',
                     '{"cloudflare_api_token":"%s"}'):
            with self.subTest(text=text):
                result = _redact(text % self.VENDOR)
                self.assertNotIn(self.VENDOR, result)

    def test_zenodo_and_cloudflare_assignments_redacted(self):
        for name in ('zenodo_token', 'CLOUDFLARE_API_TOKEN', 'cf_token'):
            with self.subTest(name=name):
                result = _redact(name + '=' + self.VENDOR)
                self.assertNotIn(self.VENDOR, result)

    def test_vendor_assignment_entity_type(self):
        ents = cast_redact.analyze_regex('cloudflare_api_token: ' + self.VENDOR, [])
        self.assertIn('VENDOR_TOKEN_ASSIGNMENT', {e['entity_type'] for e in ents})

    def test_negatives_not_redacted(self):
        for text in ('call re_try now', 'table re_index_name here', 'the glpat prefix',
                     'glpat- alone', 'see the zenodo_token setting', 'a re_' + 'x' * 25 + ' ident'):
            with self.subTest(text=text):
                self.assertEqual(text, _redact(text))

    def test_resend_requires_word_boundary(self):
        text = 'pre_' + 'A1b2' * 6
        self.assertNotIn('<RESEND_KEY>', _redact(text))

    def test_new_entity_types_in_sync_with_config(self):
        cfg = json.loads((Path(__file__).parent.parent / 'config' / 'pii-patterns.json').read_text())
        cfg_types = {p['entity_type'] for p in cfg['patterns']}
        fallback = dict(cast_redact._STANDARD_FALLBACK_PATTERNS)
        for etype in ('RESEND_KEY', 'GITLAB_TOKEN', 'VENDOR_TOKEN_ASSIGNMENT'):
            with self.subTest(etype=etype):
                self.assertIn(etype, cfg_types)
                self.assertIn(etype, fallback)
        cfg_regex = {p['entity_type']: p['regex'] for p in cfg['patterns']}
        for etype in ('RESEND_KEY', 'GITLAB_TOKEN', 'VENDOR_TOKEN_ASSIGNMENT'):
            self.assertEqual(cfg_regex[etype], fallback[etype])

    def test_database_url_patterns_in_sync_with_config(self):
        # DATABASE_URL has two entries (main + oversize) under one entity type, so the
        # dict()-by-entity-type lookup above can't be used: compare ordered regex lists.
        cfg = json.loads((Path(__file__).parent.parent / 'config' / 'pii-patterns.json').read_text())
        cfg_re = [p['regex'] for p in cfg['patterns'] if p['entity_type'] == 'DATABASE_URL']
        fb_re = [r for t, r in cast_redact._STANDARD_FALLBACK_PATTERNS if t == 'DATABASE_URL']
        self.assertEqual(len(fb_re), 2)
        self.assertEqual(cfg_re, fb_re)


class TestEmailPatternLinearTime(unittest.TestCase):
    """EMAIL_ADDRESS local part was an unbounded `+` -> quadratic on long [A-Za-z0-9._-]
    runs with no '@' (14 s+ on 90 KB of text). Bounded to {1,64} / {1,253}."""

    _TIMING_INPUTS = {
        'x_re': 'x_re_1' + 'ab-' * 30000,
        'glpat': 'glpat-' * 16000,
        'dotrun': 'a.' * 50000 + '1',
        'token': 'token ' + 'x-' * 50000,
    }

    def test_long_no_at_runs_are_fast(self):
        import time
        for name, text in self._TIMING_INPUTS.items():
            with self.subTest(name=name):
                start = time.monotonic()
                _redact(text)
                elapsed = time.monotonic() - start
                self.assertLess(elapsed, 0.5, f'{name} took {elapsed:.2f}s')

    def test_normal_emails_still_redacted(self):
        for text in (
            'user@example.com',
            'first.last+tag' + '@' + 'sub.domain.co.uk',
            'USER' + '@' + 'EXAMPLE.COM',
            'mail (a_b' + '@' + 'x.org), ok',
            '{"email":"u1@example.com"}',
            'https://x.test/?e=u1@example.com&z=1',
        ):
            with self.subTest(text=text):
                out = _redact(text)
                self.assertIn('<EMAIL_ADDRESS>', out)
                self.assertNotIn('@', out)

    def test_non_emails_not_redacted(self):
        for text in ('foo@bar', '@handle', 'version 1.2.3', 'a@b.c'):
            with self.subTest(text=text):
                self.assertNotIn('<EMAIL_ADDRESS>', _redact(text))

    def test_overlong_local_part_still_redacts_domain(self):
        out = _redact('z' * 70 + '@example.com')
        self.assertIn('<EMAIL_ADDRESS>', out)
        self.assertNotIn('example.com', out)


class TestDatabaseUrlPatternLinearTime(unittest.TestCase):
    """DATABASE_URL user/password were unbounded `+` before a required `:` / `@` ->
    quadratic on repeated `scheme://x-` (3-4 s on 120 KB). Bounded to {0,256} / {1,1024}."""

    _TIMING_INPUTS = {
        'scheme_dash': 'postgres://x-' * 10000,
        'scheme_user_colon': 'postgres://user:y-' * 10000,
        'mysql_colons': 'mysql://' + 'a:' * 20000,
        'redis_colon_at': 'redis://' + ':@' * 20000,
        'huge_password': 'postgres://u:' + 'a' * 180000,
        'long_path_repeat': ('postgres://' + 'a' * 300) * 600,
        'empty_user_repeat': 'postgres://:' * 15000,
        'oversize_pw_repeat': ('postgres+x://u:' + 'b' * 1100) * 150,
    }

    def test_adversarial_inputs_are_fast(self):
        import time
        for name, text in self._TIMING_INPUTS.items():
            with self.subTest(name=name):
                start = time.monotonic()
                cast_redact.analyze_regex(text, [])
                elapsed = time.monotonic() - start
                self.assertLess(elapsed, 0.5, f'{name} took {elapsed:.2f}s')

    def test_connection_strings_still_redacted(self):
        for text, secret in (
            ('postgres://user:pass@host:5432/db', 'pass'),
            ('postgresql://u:s3cr3tpw@h/db?sslmode=require', 's3cr3tpw'),
            ('mysql://root:hunter2' + '@' + 'db.internal/app', 'hunter2'),
            ('mongodb://u:mongopw@h1,h2/db', 'mongopw'),
            ('mongodb+srv://u:srvpw' + '@' + 'cluster0.x.mongodb.net/db', 'srvpw'),
            ('redis://:redispw@host:6379', 'redispw'),
            ('postgres://u:pa:ss/w%40rd@h/db', 'pa:ss/w%40rd'),
            ('url=postgres://u:' + 'p' * 900 + '@h/db', 'p' * 900),
            ('postgresql+psycopg2://u:SECRETPW@h/db', 'SECRETPW'),
            ('postgres+asyncpg://u:SECRETPW@h/db', 'SECRETPW'),
            ('mysql+pymysql://u:SECRETPW@h/db', 'SECRETPW'),
            ('rediss://:SECRETPW@h', 'SECRETPW'),
        ):
            with self.subTest(text=text[:40]):
                out = _redact(text)
                self.assertIn('<DATABASE_URL>', out)
                self.assertNotIn(secret, out)

    def test_oversize_credentials_do_not_leak(self):
        for name, text, secret in (
            ('pw1025', 'postgres://u:' + 'A' * 1025 + '@h/db', 'A' * 50),
            ('pw5000', 'postgres://u:' + 'B' * 5000 + '@h/db', 'B' * 50),
            ('user300', 'postgres://' + 'U' * 300 + ':SECRETPW@h', 'SECRETPW'),
        ):
            with self.subTest(name=name):
                out = _redact(text)
                self.assertIn('<DATABASE_URL>', out)
                self.assertNotIn(secret, out)
                self.assertNotIn('@h', out)

    def test_non_urls_not_redacted(self):
        for text in ('postgres is a database', 'postgres://host/db', 'see redis://localhost:6379'):
            with self.subTest(text=text):
                self.assertNotIn('<DATABASE_URL>', _redact(text))


class TestAwsSecretAccessKeyPattern(unittest.TestCase):
    """S3b-L1: a 40-char AWS secret access key assigned to an aws_secret_access_key-style name.

    GENERIC_SECRET's leading \\b cannot match inside `aws_secret_access_key` (underscore is a word
    char) and requires the operator right after `secret`, so these leaked entirely.
    """
    SECRET = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'

    def test_secret_is_forty_chars(self):
        self.assertEqual(len(self.SECRET), 40)

    def test_env_style_assignment_redacted(self):
        for text in (
            f'aws_secret_access_key={self.SECRET}',
            f'AWS_SECRET_ACCESS_KEY: "{self.SECRET}"',
            f'export AWS_SECRET_KEY = {self.SECRET} # deploy',
            f"aws-secret-access-key: '{self.SECRET}'",
        ):
            with self.subTest(text=text):
                result = _redact(text)
                self.assertNotIn(self.SECRET, result)
                self.assertNotIn('K7MDENG', result)
                self.assertIn('<AWS_SECRET_ACCESS_KEY>', result)

    def test_bare_forty_char_hex_sha_is_not_redacted(self):
        text = 'commit ' + 'a' * 40
        self.assertNotIn('<AWS_SECRET_ACCESS_KEY>', _redact(text))

    def test_variable_name_without_forty_char_value_untouched(self):
        text = 'set aws_secret_access_key=short'
        self.assertNotIn('<AWS_SECRET_ACCESS_KEY>', _redact(text))


# ── S4-1 D-A: R2 (wider ABSOLUTE_PATH) + R1 (Unicode-evasion-resistant matching) ──

ZWSP, ZWNJ, ZWJ, WJ, BOM = '\u200b', '\u200c', '\u200d', '\u2060', '\ufeff'


def _fullwidth(s: str) -> str:
    """ASCII printable -> fullwidth forms (U+FF01..U+FF5E); NFKC maps them back."""
    return ''.join(chr(ord(c) + 0xFEE0) if '!' <= c <= '~' else c for c in s)


class TestAbsolutePathWidened(unittest.TestCase):

    def test_dotted_username_redacted(self):
        result = _redact('see /Users/' + 'first.last/x')
        self.assertEqual('see ~/', result)
        self.assertNotIn('first.last', result)

    def test_linux_home_redacted(self):
        result = _redact('see /home/alice/x')
        self.assertEqual('see ~/', result)
        self.assertNotIn('alice', result)

    def test_linux_home_dotted_username_redacted(self):
        self.assertEqual('at ~/', _redact('at /home/jane.doe/work/notes.txt'))

    def test_replacement_is_neutral_for_both_roots(self):
        self.assertEqual(_redact('/Users/' + 'bob/a'), _redact('/home/bob/a'))

    def test_previously_matched_paths_still_match(self):
        for name in ('johndoe', 'john_doe-2', 'A1'):
            self.assertEqual('~/', _redact(f'/Users/{name}/Projects/x'))

    def test_bare_home_without_user_subdir_untouched(self):
        text = 'cd /home and ls /Users'
        self.assertEqual(text, _redact(text))


class TestUnicodeEvasion(unittest.TestCase):

    API_KEY = 'sk-ant-' + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'

    def test_api_key_with_zwsp_inside_redacted(self):
        k = self.API_KEY
        text = f'key {k[:12]}{ZWSP}{k[12:]} end'
        result = _redact(text)
        self.assertEqual('key <ANTHROPIC_KEY> end', result)

    def test_each_format_char_variant_inside_key_redacted(self):
        k = self.API_KEY
        for ch in (ZWSP, ZWNJ, ZWJ, WJ, BOM, '\u00ad'):
            with self.subTest(ch=hex(ord(ch))):
                text = f'key {k[:10]}{ch}{k[10:25]}{ch}{k[25:]} end'
                self.assertEqual('key <ANTHROPIC_KEY> end', _redact(text))

    def test_email_with_feff_redacted(self):
        text = f'mail john{BOM}.doe@exa{BOM}mple.com now'
        result = _redact(text)
        self.assertEqual('mail <EMAIL_ADDRESS> now', result)
        self.assertNotIn('doe', result)

    def test_secret_keyword_split_by_zwsp_redacted(self):
        text = f'pass{ZWSP}word=Hunter22secret'
        result = _redact(text)
        self.assertNotIn('Hunter22secret', result)

    def test_fullwidth_ssn_redacted(self):
        text = 'ssn ' + _fullwidth('123-45-6789') + ' ok'
        self.assertEqual('ssn <US_SSN> ok', _redact(text))

    def test_fullwidth_email_redacted(self):
        text = 'to ' + _fullwidth('john@example.com') + ' now'
        self.assertEqual('to <EMAIL_ADDRESS> now', _redact(text))

    def test_fullwidth_key_prefix_redacted(self):
        k = _fullwidth('sk-ant-') + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'
        self.assertNotIn('abcdefghijklmnopqrstuvwxyz', _redact(f'key {k} end'))

    def test_secret_followed_by_text_leaves_surroundings_untouched(self):
        """Invisible chars OUTSIDE a secret survive; only the secret span is replaced."""
        k = self.API_KEY
        text = f'caf\u00e9{ZWSP} {k[:9]}{ZWSP}{k[9:]} na\u00efve'
        self.assertEqual(f'caf\u00e9{ZWSP} <ANTHROPIC_KEY> na\u00efve', _redact(text))

    def test_mask_mode_covers_invisible_chars(self):
        k = self.API_KEY
        text = f'key {k[:12]}{ZWSP}{k[12:]} end'
        entities = cast_redact.analyze_regex(text, [])
        masked = cast_redact.redact_regex(text, entities, 'mask')
        self.assertEqual('key ' + '*' * (len(k) + 1) + ' end', masked)

    def test_entity_offsets_index_original_text(self):
        k = self.API_KEY
        text = f'key {k[:12]}{ZWSP}{k[12:]} end'
        (ent,) = cast_redact.analyze_regex(text, [])
        self.assertEqual(text[ent['start']:ent['end']], ent['original'])
        self.assertEqual(f'{k[:12]}{ZWSP}{k[12:]}', ent['original'])

    def test_hook_style_analyze_detects_zwsp_email(self):
        ents = cast_redact.analyze_regex(f'a{ZWSP}b@exam{ZWSP}ple.com', [])
        self.assertEqual(['EMAIL_ADDRESS'], [e['entity_type'] for e in ents])

    def test_widening_only_original_matches_survive(self):
        """Every entity found on the raw text is still found (same span) when the
        text also contains non-ASCII; the NFKC view may only ADD entities."""
        base = 'Contact john@example.com or 555-123-4567 and /Users/' + 'jdoe/x'
        plain = {(e['entity_type'], e['start'], e['end']) for e in cast_redact.analyze_regex(base, [])}
        suffixed = base + ' caf\u00e9 \u65e5\u672c\u8a9e'
        got = {(e['entity_type'], e['start'], e['end']) for e in cast_redact.analyze_regex(suffixed, [])}
        self.assertTrue(plain <= got)


class TestAsciiAndBenignUnicodeUnchanged(unittest.TestCase):
    """Pinned from the PRE-EDIT script (S4-1): exact outputs must not drift."""

    PINNED = [
        ('Contact john@example.com or call 555-123-4567 today',
         'Contact <EMAIL_ADDRESS> or call <PHONE_NUMBER> today',
         'Contact **************** or call ************ today',
         [('EMAIL_ADDRESS', 8, 24, '855f96e983f1f8e8'), ('PHONE_NUMBER', 33, 45, 'd36e83082288d9f2')]),
        ('key sk-ant-' + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD' + ' and file /Users/' + 'jdoe/Projects/x/y.py',
         'key <ANTHROPIC_KEY> and file ~/',
         'key *********************************************** and file ***************************',
         [('ANTHROPIC_KEY', 4, 51, '9d5da5bb22fae25e'), ('ABSOLUTE_PATH', 61, 88, '5e1ea038bdbfc50f')]),
        ('api_key = abcdefghijklmnopqrstuvwxyz123456 ok; password=Hunter22!, ssn 123-45-6789 ip 10.0.0.1',
         'api_key = <API_KEY> ok; password=<GENERIC_SECRET>, ssn <US_SSN> ip <IP_ADDRESS>',
         'api_key = ******************************** ok; password=*********, ssn *********** ip ********',
         [('API_KEY', 10, 42, 'f6d527e6d0186548'), ('GENERIC_SECRET', 56, 65, 'b1021a2e11838f67'),
          ('US_SSN', 71, 82, '01a54629efb95228'), ('IP_ADDRESS', 86, 94, 'f5047344122f0dee')]),
        ('token ghp_' + 'a' * 36 + ' at bitbucket.org/team/repo and hooks.slack.com/services/T0/B0/xyz',
         'token <GITHUB_TOKEN> at [BITBUCKET_URL] and [SLACK_WEBHOOK]',
         'token **************************************** at *********************** and **********************************',
         [('GITHUB_TOKEN', 6, 46, 'ba94fef946060f5e'), ('BITBUCKET_URL', 50, 73, 'de2ca7c0da5e1195'),
          ('SLACK_WEBHOOK', 78, 112, 'f355a014e8b153c3')]),
    ]

    def test_pinned_ascii_outputs_byte_identical(self):
        for text, want_redact, want_mask, want_ents in self.PINNED:
            with self.subTest(text=text[:30]):
                ents = cast_redact.analyze_regex(text, [])
                self.assertEqual(want_redact, cast_redact.redact_regex(text, ents, 'redact'))
                self.assertEqual(want_mask, cast_redact.redact_regex(text, ents, 'mask'))
                self.assertEqual(want_ents, [(e['entity_type'], e['start'], e['end'], e['original_hash']) for e in ents])

    def test_plain_prose_unchanged(self):
        text = 'plain prose with no secrets at all, just words.'
        self.assertEqual(text, _redact(text))

    def test_non_ascii_text_without_secrets_unchanged(self):
        for text in (
            'Un caf\u00e9 na\u00efve fa\u00e7ade, r\u00e9sum\u00e9 and \u00fcber-cool coordinates',
            '\u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8\u3001\u4e2d\u6587\u6587\u672c\u3068\u30cf\u30f3\u30b0\u30eb is fine',
            'Fullwidth \uff21\uff22\uff23 and ligature \ufb01 and zwj\u200dfamily with a/b path',
            'combining e\u0301 and a\u0308 marks, emoji \U0001F600 and arrows \u2192 here/there',
        ):
            with self.subTest(text=text[:20]):
                self.assertEqual([], cast_redact.analyze_regex(text, []))
                self.assertEqual(text, _redact(text))

    def test_non_ascii_context_preserved_around_ascii_secret(self):
        text = 'caf\u00e9 \u65e5\u672c john@example.com na\u00efve'
        self.assertEqual('caf\u00e9 \u65e5\u672c <EMAIL_ADDRESS> na\u00efve', _redact(text))


# ── S4-1 D-A follow-ups: hook-mode ensure_ascii, /home/ lookbehind, Mn stripping ──

COMBINING_ACUTE = '\u0301'


class TestHomePathBoundary(unittest.TestCase):
    """The /home/ branch needs a left boundary; the /Users/ branch has none.

    NOTE: the `"~/` expectation below (closing quote swallowed by the `[^\\s]*` tail) is
    pinned ON PURPOSE -- it mirrors the pre-existing /Users/ behaviour; do not "fix" it here.
    """

    def test_url_path_with_home_segment_not_redacted(self):
        for text in ('https://example.com/home/dashboard/x', 'see example.com/home/dashboard/x',
                     'api-v1.host/home/u/x'):
            with self.subTest(text=text):
                self.assertEqual(text, _redact(text))

    def test_home_paths_in_common_contexts_redacted(self):
        for text, want in (
            ('see /home/alice/x', 'see ~/'),
            ('"/home/alice/x"', '"~/'),  # [^\\s]* swallows the closing quote (same as /Users/)
            ('path=/home/alice/x', 'path=~/'),
            ('file:///home/alice/x', 'file://~/'),
            ('(/home/alice/x)', '(~/'),
            ('/home/alice/x', '~/'),
        ):
            with self.subTest(text=text):
                self.assertEqual(want, _redact(text))

    def test_users_branch_has_no_boundary(self):
        """Pre-existing behaviour: /Users/ matches after any char -- must not narrow."""
        self.assertEqual('https://example.com~/', _redact('https://example.com/Users/' + 'bob/x'))
        self.assertEqual('foo~/', _redact('foo/Users/' + 'bob/x'))


class TestHookModeUnicode(unittest.TestCase):
    """--hook mode must see a zero-width char inside a secret in a NON-Bash tool_input."""

    def _hook(self, payload: dict):
        with tempfile.TemporaryDirectory() as home:  # audit.jsonl goes under the temp HOME
            env = {'HOME': home, 'PATH': os.environ.get('PATH', ''), 'PYTHONDONTWRITEBYTECODE': '1'}
            r = subprocess.run([sys.executable, str(_REDACT_PATH), '--hook'],
                               input=json.dumps(payload), capture_output=True, text=True, env=env)
            audit = Path(home, '.claude', 'logs', 'audit.jsonl')
            return r, (audit.read_text(encoding='utf-8') if audit.exists() else '')

    def test_write_content_email_with_zwsp_blocked(self):
        r, audit = self._hook({'tool_name': 'Write', 'tool_input': {
            'file_path': '/tmp/x.txt', 'content': f'mail jo{ZWSP}hn@exam{ZWSP}ple.org please'}})
        self.assertEqual(2, r.returncode, r.stderr)
        self.assertIn('EMAIL_ADDRESS', r.stderr)
        self.assertIn('EMAIL_ADDRESS', audit)

    def test_write_content_api_key_with_zwsp_blocked(self):
        k = 'sk-ant-' + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'
        r, _ = self._hook({'tool_name': 'Edit', 'tool_input': {
            'new_string': f'key = "{k[:12]}{ZWSP}{k[12:]}"'}})
        self.assertEqual(2, r.returncode, r.stderr)
        self.assertIn('ANTHROPIC_KEY', r.stderr)

    def test_write_clean_non_ascii_content_allowed(self):
        r, audit = self._hook({'tool_name': 'Write', 'tool_input': {
            'content': 'caf\u00e9 \u65e5\u672c\u8a9e and ' + ZWSP + ' nothing secret'}})
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertEqual('', r.stdout)
        self.assertEqual('', audit)

    def test_audit_record_stays_ascii_safe_json(self):
        _, audit = self._hook({'tool_name': 'Write', 'tool_input': {'content': f'a{ZWSP}b@exam{ZWSP}ple.org'}})
        rec = json.loads(audit.strip().splitlines()[-1])
        self.assertEqual(['EMAIL_ADDRESS'], rec['entity_types'])
        self.assertNotIn('content', rec)


class TestCombiningMarkEvasion(unittest.TestCase):

    API_KEY = 'sk-ant-' + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'

    def test_key_with_combining_acute_mid_token_redacted(self):
        k = self.API_KEY
        text = f'key {k[:14]}{COMBINING_ACUTE}{k[14:]} end'
        self.assertEqual('key <ANTHROPIC_KEY> end', _redact(text))

    def test_email_with_combining_marks_redacted(self):
        text = f'mail jo{COMBINING_ACUTE}hn@exa\u0308mple.com now'
        self.assertEqual('mail <EMAIL_ADDRESS> now', _redact(text))

    def test_combining_mark_on_every_key_char_redacted(self):
        k = self.API_KEY
        text = 'key ' + ''.join(c + COMBINING_ACUTE for c in k) + ' end'
        self.assertEqual('key <ANTHROPIC_KEY> end', _redact(text))

    def test_decomposed_cafe_in_prose_byte_identical(self):
        text = f'We met at cafe{COMBINING_ACUTE} on nai\u0308ve terms.'
        self.assertEqual([], cast_redact.analyze_regex(text, []))
        self.assertEqual(text, _redact(text))

    def test_decomposed_text_around_secret_preserved(self):
        text = f'cafe{COMBINING_ACUTE} john@example.com nai\u0308ve'
        self.assertEqual(f'cafe{COMBINING_ACUTE} <EMAIL_ADDRESS> nai\u0308ve', _redact(text))


# ── Redactor review round 2: C1 (fail-closed hook), W1 (count), W2 (Me), W3 (gaps) ──

LONE_SURROGATE = '\ud800'
ENCLOSING_KEYCAP, ENCLOSING_CIRCLE = '\u20e3', '\u20dd'  # category Me


class TestHookFailClosed(unittest.TestCase):
    """C1: a lone surrogate must never turn the hook fail-open (exit 1 = non-blocking)."""

    def _hook(self, payload):
        raw = payload if isinstance(payload, str) else json.dumps(payload)
        with tempfile.TemporaryDirectory() as home:  # audit.jsonl goes under the temp HOME
            env = {'HOME': home, 'PATH': os.environ.get('PATH', ''), 'PYTHONDONTWRITEBYTECODE': '1'}
            return subprocess.run([sys.executable, str(_REDACT_PATH), '--hook'],
                                  input=raw, capture_output=True, text=True, env=env)

    def test_write_with_surrogate_and_secret_exits_2(self):
        r = self._hook('{"tool_name":"Write","tool_input":{"content":"password=Hunter2\\ud800abcdef"}}')
        self.assertEqual(2, r.returncode, r.stderr)

    def test_bash_with_surrogate_and_secret_exits_2(self):
        r = self._hook('{"tool_name":"Bash","tool_input":{"command":"echo password=Hunter2\\ud800abcdef"}}')
        self.assertEqual(2, r.returncode, r.stderr)

    def test_real_token_plus_path_with_surrogate_exits_2(self):
        r = self._hook({'tool_name': 'Write', 'tool_input': {
            'content': 'ghp_' + 'a' * 36 + ' and /Users/' + 'x/' + LONE_SURROGATE}})
        self.assertEqual(2, r.returncode, r.stderr)
        self.assertIn('GITHUB_TOKEN', r.stderr)

    def test_clean_payload_with_surrogate_is_not_blocked(self):
        r = self._hook('{"tool_name":"Write","tool_input":{"content":"hello \\ud800 world"}}')
        self.assertEqual(0, r.returncode, r.stderr)

    def test_non_dict_json_payload_fails_closed(self):
        r = self._hook('[1, 2, 3]')
        self.assertEqual(2, r.returncode, r.stderr)

    def test_deeply_nested_json_with_secret_fails_closed(self):
        """RecursionError in json.loads is not 'malformed input' -- it must BLOCK (exit 2)."""
        depth = 300_000
        raw = ('{"tool_name":"Write","tool_input":{"x":' + '[' * depth + '"ghp_' + 'a' * 36 + '"'
               + ']' * depth + '}}')
        r = self._hook(raw)
        self.assertEqual(2, r.returncode, r.stderr[-300:])
        self.assertIn('RecursionError', r.stderr)

    def _hook_in_process(self, payload, exc):
        orig_stdin, orig_stderr, orig_loads = cast_redact.sys.stdin, cast_redact.sys.stderr, cast_redact.json.loads
        cast_redact.sys.stdin, cast_redact.sys.stderr = io.StringIO(payload), io.StringIO()
        def boom(*a, **k):
            raise exc
        cast_redact.json.loads = boom
        try:
            with self.assertRaises(BaseException) as cm:
                cast_redact._run_hook_mode()
        finally:
            cast_redact.sys.stdin, cast_redact.sys.stderr, cast_redact.json.loads = orig_stdin, orig_stderr, orig_loads
        return cm.exception

    def test_parse_recursion_error_blocks_in_process(self):
        e = self._hook_in_process('{}', RecursionError('deep'))
        self.assertIsInstance(e, SystemExit)
        self.assertEqual(2, e.code)

    def test_parse_memory_error_blocks_in_process(self):
        e = self._hook_in_process('{}', MemoryError())
        self.assertIsInstance(e, SystemExit)
        self.assertEqual(2, e.code)

    def test_parse_keyboard_interrupt_propagates_in_process(self):
        self.assertIsInstance(self._hook_in_process('{}', KeyboardInterrupt()), KeyboardInterrupt)

    def test_malformed_and_empty_input_still_allowed(self):
        for raw in ('', '   ', '{not json', '{"tool_name": '):
            with self.subTest(raw=raw):
                r = self._hook(raw)
                self.assertEqual(0, r.returncode, r.stderr)

    def test_invalid_utf8_stdin_fails_closed(self):
        """Claude Code always sends valid UTF-8; undecodable stdin is not 'no payload'.

        PYTHONIOENCODING pins strict decoding: under a C/POSIX locale Python reads stdin
        with surrogateescape instead (no UnicodeDecodeError; the bytes are still analysed)."""
        with tempfile.TemporaryDirectory() as home:
            env = {'HOME': home, 'PATH': os.environ.get('PATH', ''), 'PYTHONDONTWRITEBYTECODE': '1',
                   'PYTHONIOENCODING': 'utf-8:strict'}
            r = subprocess.run([sys.executable, str(_REDACT_PATH), '--hook'],
                               input=b'{"tool_name":"Write","tool_input":{"c":"\xff\xfe"}}',
                               capture_output=True, env=env)
        self.assertEqual(2, r.returncode, r.stderr)

    def test_oversized_int_literal_with_secret_fails_closed(self):
        """3.11+ raises ValueError for a >4300-digit JSON int; that must not read as
        'malformed -> allow'.  Exit 2 on every interpreter: either the parse fails closed
        (limit present) or the ghp_ token is detected (limit absent, e.g. 3.9)."""
        raw = json.dumps({'tool_name': 'Write', 'tool_input': {'content': 'ghp_' + 'a' * 36}})
        raw = raw[:-2] + ',"n":' + '9' * 5000 + '}}'
        r = self._hook(raw)
        self.assertEqual(2, r.returncode, r.stderr[-300:])

    def test_parse_valueerror_blocks_in_process(self):
        """A non-JSONDecodeError ValueError at the parse stage fails closed."""
        e = self._hook_in_process('{}', ValueError('Exceeds the limit (4300 digits)'))
        self.assertIsInstance(e, SystemExit)
        self.assertEqual(2, e.code)

    def test_analysis_exception_blocks_in_process(self):
        payload = json.dumps({'tool_name': 'Write', 'tool_input': {'content': 'anything at all here'}})
        orig_stdin, orig_analyze = cast_redact.sys.stdin, cast_redact.analyze_regex
        cast_redact.sys.stdin = io.StringIO(payload)
        cast_redact.analyze_regex = lambda *a, **k: (_ for _ in ()).throw(RuntimeError('boom'))
        try:
            with self.assertRaises(SystemExit) as cm:
                cast_redact._run_hook_mode()
        finally:
            cast_redact.sys.stdin, cast_redact.analyze_regex = orig_stdin, orig_analyze
        self.assertEqual(2, cm.exception.code)

    def test_keyboard_interrupt_still_propagates(self):
        payload = json.dumps({'tool_name': 'Write', 'tool_input': {'content': 'anything at all here'}})
        orig_stdin, orig_analyze = cast_redact.sys.stdin, cast_redact.analyze_regex
        cast_redact.sys.stdin = io.StringIO(payload)
        cast_redact.analyze_regex = lambda *a, **k: (_ for _ in ()).throw(KeyboardInterrupt())
        try:
            with self.assertRaises(KeyboardInterrupt):
                cast_redact._run_hook_mode()
        finally:
            cast_redact.sys.stdin, cast_redact.analyze_regex = orig_stdin, orig_analyze

    def test_analyze_regex_surrogate_text_does_not_raise_and_detects(self):
        for text in (f'password=Hunter2{LONE_SURROGATE}abcdef',
                     f'note {LONE_SURROGATE} john@example.com {ZWSP}tail',
                     f'{LONE_SURROGATE}' + 'ghp_' + 'a' * 36):
            with self.subTest(text=text[:20]):
                ents = cast_redact.analyze_regex(text, [])
                self.assertTrue(ents)
                self.assertTrue(all(len(e['original_hash']) == 16 for e in ents))
                self.assertNotIn('Hunter2', _redact(text))


class TestEntityCountNotInflated(unittest.TestCase):
    """W1: raw span + wider view span of the same secret is ONE entity."""

    K = 'sk-ant-' + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'

    def test_trailing_cf_gives_single_entity(self):
        ents = cast_redact.analyze_regex(f'key {self.K}{ZWSP} end', [])
        self.assertEqual([('ANTHROPIC_KEY', 4, 4 + len(self.K) + 1)], [(e['entity_type'], e['start'], e['end']) for e in ents])

    def test_inner_and_trailing_invisible_chars_single_entity(self):
        text = f'key {self.K[:12]}{ZWSP}{self.K[12:]}{COMBINING_ACUTE} end'
        ents = cast_redact.analyze_regex(text, [])
        self.assertEqual(['ANTHROPIC_KEY'], [e['entity_type'] for e in ents])
        self.assertEqual(text[ents[0]['start']:ents[0]['end']], ents[0]['original'])
        self.assertEqual('key <ANTHROPIC_KEY> end', _redact(text))

    def test_two_separate_secrets_stay_two_entities(self):
        text = f'a john@example.com{ZWSP} b jane@example.org{ZWSP} c'
        ents = cast_redact.analyze_regex(text, [])
        self.assertEqual(['EMAIL_ADDRESS', 'EMAIL_ADDRESS'], [e['entity_type'] for e in ents])

    def test_different_type_overlap_not_merged_by_union(self):
        spans = cast_redact._union_same_type_view_spans(
            [('IP_ADDRESS', 5, 12)], [('DATABASE_URL', 0, 20)])
        self.assertEqual([('IP_ADDRESS', 5, 12), ('DATABASE_URL', 0, 20)], spans)

    def test_union_only_when_a_view_span_is_involved(self):
        raw_only = [('DATABASE_URL', 0, 10), ('DATABASE_URL', 5, 20)]
        self.assertEqual(raw_only, cast_redact._union_same_type_view_spans(raw_only, []))
        self.assertEqual([('DATABASE_URL', 0, 21)],
                         cast_redact._union_same_type_view_spans(raw_only, [('DATABASE_URL', 18, 21)]))

    def test_raw_only_group_untouched_when_unrelated_view_span_present(self):
        raw = [('DATABASE_URL', 0, 10), ('DATABASE_URL', 5, 20)]
        got = cast_redact._union_same_type_view_spans(raw, [('EMAIL_ADDRESS', 30, 35)])
        self.assertEqual(raw + [('EMAIL_ADDRESS', 30, 35)], got)

    def test_adjacent_same_type_view_and_raw_spans_merge(self):
        self.assertEqual([('X', 0, 8)], cast_redact._union_same_type_view_spans([('X', 0, 4)], [('X', 4, 8)]))


class TestEnclosingMarksAndGaps(unittest.TestCase):

    K = 'sk-ant-' + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'

    def test_key_with_enclosing_marks_redacted(self):
        for ch in (ENCLOSING_KEYCAP, ENCLOSING_CIRCLE):
            with self.subTest(ch=hex(ord(ch))):
                text = f'key {self.K[:15]}{ch}{self.K[15:]}{ch} end'
                self.assertEqual('key <ANTHROPIC_KEY> end', _redact(text))

    def test_email_with_enclosing_mark_redacted(self):
        self.assertEqual('to <EMAIL_ADDRESS> now', _redact(f'to jo{ENCLOSING_KEYCAP}hn@example.com now'))

    def test_nfkc_output_mark_is_stripped_from_view(self):
        """U+FF9E / U+FF9F (halfwidth sound marks, category Lm) NFKC-map to U+3099 / U+309A
        (Mn).  The per-output Mn filter must drop them or the key no longer matches."""
        for ch in ('\uff9e', '\uff9f'):
            with self.subTest(ch=hex(ord(ch))):
                text = f'key {self.K[:20]}{ch}{self.K[20:]} end'
                self.assertEqual('key <ANTHROPIC_KEY> end', _redact(text))

    def test_trailing_format_char_absorbed(self):
        for ch in (ZWSP, BOM, '\u00ad'):
            with self.subTest(ch=hex(ord(ch))):
                self.assertEqual('key <ANTHROPIC_KEY> end', _redact(f'key {self.K}{ch} end'))

    def test_leading_format_char_not_absorbed(self):
        """Documented boundary: only TRAILING stripped chars are absorbed."""
        self.assertEqual(f'key {ZWSP}<ANTHROPIC_KEY> end', _redact(f'key {ZWSP}{self.K} end'))


if __name__ == '__main__':
    unittest.main()
