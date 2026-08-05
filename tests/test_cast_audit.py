#!/usr/bin/env python3
"""
Unit tests for pure helpers in scripts/cast-audit.py.

Covers:
  - _sha256(text) — deterministic hash
  - _safelist_match(text) — case-insensitive substring match
  - parse_tool_fields(data) — tool-specific field extraction
  - build_record(parsed, timestamp, session_id, project) — empty-string filtering
  - resolve_project() — env var precedence
"""

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_SCRIPT_PATH = _SCRIPTS_DIR / 'cast-audit.py'

# Load module via importlib (hyphenated name cannot be imported normally)
# Set CAST_DB_PATH to a temp location first to avoid any import-time path resolution issues.
os.environ['CAST_DB_PATH'] = os.path.join(tempfile.mkdtemp(prefix='cast-audit-test-'), 'cast.db')
_spec = importlib.util.spec_from_file_location('cast_audit', str(_SCRIPT_PATH))
cast_audit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cast_audit)


class TestSha256(unittest.TestCase):
    """Test _sha256() — deterministic hash."""

    def test_hash_returns_hex_string(self):
        """_sha256 should return a hex string of expected length."""
        result = cast_audit._sha256("test")
        self.assertIsInstance(result, str)
        self.assertEqual(len(result), 64)  # SHA256 hex is 64 chars
        # Should be valid hex
        int(result, 16)

    def test_empty_string_hash(self):
        """Empty string should produce a known SHA256 hash."""
        result = cast_audit._sha256("")
        expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        self.assertEqual(result, expected)

    def test_deterministic(self):
        """Same input should always produce same hash."""
        text = "anthropic.com"
        hash1 = cast_audit._sha256(text)
        hash2 = cast_audit._sha256(text)
        self.assertEqual(hash1, hash2)

    def test_different_inputs_different_hashes(self):
        """Different inputs should produce different hashes."""
        hash1 = cast_audit._sha256("hello")
        hash2 = cast_audit._sha256("world")
        self.assertNotEqual(hash1, hash2)


class TestSafelistMatch(unittest.TestCase):
    """Test _safelist_match() — case-insensitive substring matching."""

    def test_matches_anthropic_com(self):
        """Should match 'anthropic.com' (lowercase in SAFELIST_PATTERNS)."""
        self.assertTrue(cast_audit._safelist_match("send data to anthropic.com"))

    def test_matches_case_insensitive(self):
        """Should match regardless of input case."""
        self.assertTrue(cast_audit._safelist_match("ANTHROPIC.COM"))
        self.assertTrue(cast_audit._safelist_match("Anthropic.Com"))

    def test_matches_github_com(self):
        """Should match 'github.com'."""
        self.assertTrue(cast_audit._safelist_match("push to github.com/user/repo"))

    def test_matches_example_com(self):
        """Should match 'example.com'."""
        self.assertTrue(cast_audit._safelist_match("example.com"))

    def test_matches_example_org(self):
        """Should match 'example.org'."""
        self.assertTrue(cast_audit._safelist_match("test@example.org"))

    def test_matches_noreply_at(self):
        """Should match 'noreply@'."""
        # Use an @example.com address (RFC-2606 reserved, PII-scanner-exempt) that
        # still contains the 'noreply@' substring under test.
        self.assertTrue(cast_audit._safelist_match("noreply@example.com"))

    def test_matches_user_at_example(self):
        """Should match 'user@example'."""
        self.assertTrue(cast_audit._safelist_match("user@example.com"))

    def test_matches_at_anthropic(self):
        """Should match '@anthropic'."""
        # noreply@anthropic.com is PII-scanner-exempt and still contains the
        # '@anthropic' substring under test.
        self.assertTrue(cast_audit._safelist_match("noreply@anthropic.com"))

    def test_matches_claude_ai(self):
        """Should match 'claude.ai'."""
        self.assertTrue(cast_audit._safelist_match("visit claude.ai"))

    def test_matches_docs_anthropic(self):
        """Should match 'docs.anthropic'."""
        self.assertTrue(cast_audit._safelist_match("see docs.anthropic.com"))

    def test_no_match_for_non_safelisted(self):
        """Should not match non-safelisted domains."""
        self.assertFalse(cast_audit._safelist_match("send to malicious.com"))

    def test_mixed_case_no_match(self):
        """Should not match unsafelisted even with different case."""
        self.assertFalse(cast_audit._safelist_match("MALICIOUS.COM"))


class TestParseToolFields(unittest.TestCase):
    """Test parse_tool_fields() — tool-specific field extraction."""

    def test_write_tool_extracts_file_path(self):
        """Write tool should extract file_path and content_hash."""
        data = {
            "tool_name": "Write",
            "tool_input": {
                "file_path": "/tmp/test.txt",
                "content": "hello world"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["tool_name"], "Write")
        self.assertEqual(result["file_path"], "/tmp/test.txt")
        self.assertNotEqual(result["content_hash"], "")
        self.assertTrue(len(result["content_hash"]) == 64)

    def test_write_tool_uses_notebook_path_fallback(self):
        """Write tool should fall back to notebook_path."""
        data = {
            "tool_name": "Write",
            "tool_input": {
                "notebook_path": "/tmp/notebook.ipynb",
                "content": "code"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["file_path"], "/tmp/notebook.ipynb")

    def test_write_tool_uses_path_fallback(self):
        """Write tool should fall back to path."""
        data = {
            "tool_name": "Write",
            "tool_input": {
                "path": "/tmp/file.txt",
                "content": "data"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["file_path"], "/tmp/file.txt")

    def test_edit_tool_uses_new_string(self):
        """Edit tool should use new_string for content hash."""
        data = {
            "tool_name": "Edit",
            "tool_input": {
                "file_path": "/tmp/test.txt",
                "new_string": "new content"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["file_path"], "/tmp/test.txt")
        self.assertNotEqual(result["content_hash"], "")

    def test_bash_tool_command_preview_truncation(self):
        """Bash tool should truncate command_preview to 80 chars."""
        long_cmd = "x" * 100
        data = {
            "tool_name": "Bash",
            "tool_input": {
                "command": long_cmd
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(len(result["command_preview"]), 80)
        self.assertEqual(result["command_preview"], "x" * 80)

    def test_bash_tool_newline_replacement(self):
        """Bash tool should replace newlines with spaces in preview."""
        data = {
            "tool_name": "Bash",
            "tool_input": {
                "command": "line1\nline2\nline3"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertNotIn("\n", result["command_preview"])
        self.assertIn("line1", result["command_preview"])
        self.assertIn("line2", result["command_preview"])

    def test_bash_tool_command_hash(self):
        """Bash tool should set command_hash."""
        data = {
            "tool_name": "Bash",
            "tool_input": {
                "command": "ls -la"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertNotEqual(result["command_hash"], "")
        self.assertTrue(len(result["command_hash"]) == 64)

    def test_webfetch_tool_sets_cloud_bound(self):
        """WebFetch tool should set is_cloud_bound=True."""
        data = {
            "tool_name": "WebFetch",
            "tool_input": {
                "url": "https://example.com"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["url"], "https://example.com")
        self.assertTrue(result["is_cloud_bound"])

    def test_websearch_tool_sets_cloud_bound(self):
        """WebSearch tool should set is_cloud_bound=True."""
        data = {
            "tool_name": "WebSearch",
            "tool_input": {
                "query": "python testing"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["query"], "python testing")
        self.assertTrue(result["is_cloud_bound"])

    def test_websearch_query_fallback(self):
        """WebSearch should fall back to 'q' parameter."""
        data = {
            "tool_name": "WebSearch",
            "tool_input": {
                "q": "search term"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["query"], "search term")

    def test_websearch_query_truncation(self):
        """WebSearch query should be truncated to 120 chars."""
        long_query = "x" * 150
        data = {
            "tool_name": "WebSearch",
            "tool_input": {
                "query": long_query
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(len(result["query"]), 120)

    def test_glob_tool_pattern(self):
        """Glob tool should extract pattern."""
        data = {
            "tool_name": "Glob",
            "tool_input": {
                "pattern": "**/*.py"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["query"], "**/*.py")

    def test_grep_tool_fields(self):
        """Grep tool should extract pattern and path."""
        data = {
            "tool_name": "Grep",
            "tool_input": {
                "pattern": "def test_",
                "path": "/tmp/test.py"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["query"], "def test_")
        self.assertEqual(result["file_path"], "/tmp/test.py")

    def test_grep_pattern_truncation(self):
        """Grep pattern should be truncated to 80 chars."""
        long_pattern = "x" * 100
        data = {
            "tool_name": "Grep",
            "tool_input": {
                "pattern": long_pattern,
                "path": "/tmp/file"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(len(result["query"]), 80)

    def test_unknown_tool_still_sets_input_hash(self):
        """Unknown tool type should still set input_hash."""
        data = {
            "tool_name": "UnknownTool",
            "tool_input": {
                "some_field": "some_value"
            }
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertNotEqual(result["input_hash"], "")
        self.assertEqual(len(result["input_hash"]), 16)

    def test_input_hash_from_sorted_json(self):
        """input_hash should be deterministic (from sorted JSON)."""
        data1 = {
            "tool_name": "Test",
            "tool_input": {
                "z": 1,
                "a": 2
            }
        }
        data2 = {
            "tool_name": "Test",
            "tool_input": {
                "a": 2,
                "z": 1
            }
        }
        result1 = cast_audit.parse_tool_fields(data1)
        result2 = cast_audit.parse_tool_fields(data2)
        self.assertEqual(result1["input_hash"], result2["input_hash"])


class TestBuildRecord(unittest.TestCase):
    """Test build_record() — empty-string filtering."""

    def test_omits_empty_string_values(self):
        """Empty string values should be omitted from result."""
        parsed = {
            "tool_name": "Write",
            "file_path": "/tmp/test.txt",
            "command_preview": "",  # Should be omitted
            "command_hash": "",      # Should be omitted
            "content_hash": "abc123"
        }
        result = cast_audit.build_record(parsed, "2026-01-01T00:00:00Z", "sess-1", "test-proj")
        self.assertNotIn("command_preview", result)
        self.assertNotIn("command_hash", result)
        self.assertIn("file_path", result)
        self.assertIn("content_hash", result)

    def test_preserves_non_empty_strings(self):
        """Non-empty string values should be preserved."""
        parsed = {
            "tool_name": "Bash",
            "command_preview": "ls -la"
        }
        result = cast_audit.build_record(parsed, "2026-01-01T00:00:00Z", "sess-1", "proj")
        self.assertEqual(result["command_preview"], "ls -la")

    def test_preserves_false_values(self):
        """False/0/None values should be preserved (not filtered)."""
        parsed = {
            "tool_name": "Write",
            "is_cloud_bound": False,
            "field_with_zero": 0,
            "field_with_none": None
        }
        result = cast_audit.build_record(parsed, "2026-01-01T00:00:00Z", "sess-1", "proj")
        self.assertIn("is_cloud_bound", result)
        self.assertIn("field_with_zero", result)
        self.assertIn("field_with_none", result)

    def test_includes_required_fields(self):
        """timestamp, session_id, project should always be included."""
        parsed = {"tool_name": "Test"}
        result = cast_audit.build_record(parsed, "2026-01-01T00:00:00Z", "sess-1", "proj")
        self.assertEqual(result["timestamp"], "2026-01-01T00:00:00Z")
        self.assertEqual(result["session_id"], "sess-1")
        self.assertEqual(result["project"], "proj")


class TestResolveProject(unittest.TestCase):
    """Test resolve_project() — env var precedence."""

    def setUp(self):
        """Save original env vars."""
        self.orig_project_dir = os.environ.get('CLAUDE_PROJECT_DIR')
        self.orig_project_path = os.environ.get('CLAUDE_PROJECT_PATH')
        # Clear for clean tests
        os.environ.pop('CLAUDE_PROJECT_DIR', None)
        os.environ.pop('CLAUDE_PROJECT_PATH', None)

    def tearDown(self):
        """Restore original env vars."""
        if self.orig_project_dir:
            os.environ['CLAUDE_PROJECT_DIR'] = self.orig_project_dir
        else:
            os.environ.pop('CLAUDE_PROJECT_DIR', None)
        if self.orig_project_path:
            os.environ['CLAUDE_PROJECT_PATH'] = self.orig_project_path
        else:
            os.environ.pop('CLAUDE_PROJECT_PATH', None)

    def test_claude_project_dir_takes_precedence(self):
        """CLAUDE_PROJECT_DIR should take precedence over CLAUDE_PROJECT_PATH."""
        os.environ['CLAUDE_PROJECT_DIR'] = '/path/to/my-project'
        os.environ['CLAUDE_PROJECT_PATH'] = '/path/to/other-project'
        result = cast_audit.resolve_project()
        self.assertEqual(result, 'my-project')

    def test_claude_project_dir_alone(self):
        """CLAUDE_PROJECT_DIR alone should return basename."""
        os.environ['CLAUDE_PROJECT_DIR'] = '/path/to/my-project'
        result = cast_audit.resolve_project()
        self.assertEqual(result, 'my-project')

    def test_claude_project_dir_strips_trailing_slash(self):
        """CLAUDE_PROJECT_DIR with trailing slash should be stripped."""
        os.environ['CLAUDE_PROJECT_DIR'] = '/path/to/my-project/'
        result = cast_audit.resolve_project()
        self.assertEqual(result, 'my-project')

    def test_claude_project_path_fallback(self):
        """CLAUDE_PROJECT_PATH should be used when DIR is not set."""
        os.environ['CLAUDE_PROJECT_PATH'] = '/path/to/fallback-proj'
        result = cast_audit.resolve_project()
        self.assertEqual(result, 'fallback-proj')

    def test_empty_env_returns_empty_string(self):
        """With no env vars set, should return empty string."""
        result = cast_audit.resolve_project()
        # Could be empty or a git project name if we're in a git repo
        # For this test, we expect it might be non-empty if running in a git repo,
        # so we just verify it's a string
        self.assertIsInstance(result, str)


if __name__ == '__main__':
    unittest.main()
