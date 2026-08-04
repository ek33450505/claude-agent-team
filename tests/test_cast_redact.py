#!/usr/bin/env python3
"""Tests for new FALLBACK_PATTERNS added to cast-redact.py.

Covers:
  ABSOLUTE_PATH — /Users/<name>/... → ~/
  BITBUCKET_URL — bitbucket.org/... → [BITBUCKET_URL]
  SLACK_WEBHOOK — hooks.slack.com/... → [SLACK_WEBHOOK]
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
        text = 'path /Users/alice/file.txt'
        entities = cast_redact.analyze_regex(text, [])
        result = cast_redact.redact_regex(text, entities, mode='mask')
        self.assertNotIn('~/', result)
        self.assertIn('*', result)


if __name__ == '__main__':
    unittest.main()
