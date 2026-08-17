#!/usr/bin/env python3
"""Tests for new FALLBACK_PATTERNS added to cast-redact.py.

Covers:
  ABSOLUTE_PATH — /Users/<name>/... → ~/
  BITBUCKET_URL — bitbucket.org/... → [BITBUCKET_URL]
  SLACK_WEBHOOK — hooks.slack.com/... → [SLACK_WEBHOOK]
  STRIPE_KEY, SLACK_TOKEN, NPM_TOKEN, SENDGRID_KEY, GOOGLE_API_KEY, GENERIC_SECRET
    (C1b: closing redaction-engine blind spots — see _PII_CANDIDATES superset invariant test)
"""
import importlib.util
import unittest
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

    def test_no_match_on_linux_home(self):
        """Linux /home/ paths are not covered by this pattern (scope: macOS /Users/)."""
        text = 'path at /home/ubuntu/projects/'
        result = _redact(text)
        # Pattern only matches /Users/... so this should be unchanged
        self.assertEqual(text, result)


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
        'GENERIC_SECRET': 'password=hunter',
    }

    def test_all_patterns_have_samples(self):
        pattern_types = {etype for etype, _ in cast_redact.FALLBACK_PATTERNS}
        self.assertEqual(pattern_types, set(self._SAMPLES.keys()))

    def test_every_pattern_sample_matches_pii_candidates(self):
        for etype, pat in cast_redact.FALLBACK_PATTERNS:
            sample = self._SAMPLES[etype]
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


if __name__ == '__main__':
    unittest.main()
