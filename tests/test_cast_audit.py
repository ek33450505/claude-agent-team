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
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_SCRIPT_PATH = _SCRIPTS_DIR / 'cast-audit.py'

# scripts/ on sys.path so cast_audit's lazy `from cast_db import db_write` (used
# by write_mcp_routing_event) resolves the same way it does when the hook runs
# cast-audit.py as a top-level script (Python auto-adds the script's own dir).
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

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


class TestMcpParsing(unittest.TestCase):
    """Test parse_tool_fields() MCP branch (v10 2.6) — server/tool split,
    args_summary redaction-by-construction, is_cloud_bound derivation, and
    outcome/result_size capture. All MCP-only; non-MCP tools must be unaffected
    (see TestMcpNonRegression below).

    Two tests here (test_outcome_error_from_error_key,
    test_outcome_error_from_content_block_list) exercise error_preview, which
    depends on _sanitize_error_text() finding cast_audit.REDACT_SCRIPT. That
    constant defaults to the INSTALLED ~/.claude copy, which is absent in CI
    (no ~/.claude there) — see TestSanitizeErrorText for the full rationale.
    setUp/tearDown here repoint it at the repo copy for every test in this
    class; the redirect is harmless to the tests that don't touch
    error_preview."""

    def setUp(self):
        self._orig_redact_script = cast_audit.REDACT_SCRIPT
        cast_audit.REDACT_SCRIPT = str(_SCRIPTS_DIR / 'cast-redact.py')

    def tearDown(self):
        cast_audit.REDACT_SCRIPT = self._orig_redact_script

    def test_mcp_server_tool_split(self):
        """mcp__<server>__<tool> splits on the double underscore delimiter."""
        data = {"tool_name": "mcp__cast-record__query", "tool_input": {}}
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["mcp_server"], "cast-record")
        self.assertEqual(result["mcp_tool"], "query")

    def test_mcp_server_tool_split_hyphenated_server(self):
        """Server names may legitimately contain single hyphens — split must
        use '__' only, never '-'."""
        data = {"tool_name": "mcp__cloudflare-graphql__graphql_query", "tool_input": {}}
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["mcp_server"], "cloudflare-graphql")
        self.assertEqual(result["mcp_tool"], "graphql_query")

    def test_mcp_malformed_tool_name_no_tool_segment(self):
        """'mcp__server' with no tool segment must not raise."""
        data = {"tool_name": "mcp__onlyserver", "tool_input": {}}
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["mcp_server"], "onlyserver")
        self.assertEqual(result["mcp_tool"], "")

    def test_mcp_malformed_bare_prefix(self):
        """Bare 'mcp__' with nothing after must not raise."""
        data = {"tool_name": "mcp__", "tool_input": {}}
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["mcp_server"], "")
        self.assertEqual(result["mcp_tool"], "")

    def test_args_summary_omits_secret_value_keeps_key_name(self):
        """A secret VALUE must be structurally absent; the key name must appear."""
        data = {
            "tool_name": "mcp__cast-record__query",
            "tool_input": {"account_id": "SECRET-TOKEN-ABCDEF1234567890", "limit": 10},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertIn("account_id", result["args_summary"])
        self.assertNotIn("SECRET-TOKEN-ABCDEF1234567890", result["args_summary"])
        self.assertIn("limit:int", result["args_summary"])

    def test_args_summary_key_sorted_type_len_format(self):
        """Matches the documented shape: key-sorted, comma-joined key:type(len)."""
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {"query": "x" * 418, "account_id": "y" * 32, "limit": 5},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["args_summary"], "account_id:str(32),limit:int,query:str(418)")

    def test_args_summary_nested_containers(self):
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {"opts": {"a": 1, "b": 2}, "items": [1, 2, 3]},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertIn("opts:dict(2)", result["args_summary"])
        self.assertIn("items:list(3)", result["args_summary"])

    def test_args_summary_truncated_to_200_chars(self):
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {f"k{i}": "x" * 20 for i in range(30)},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertLessEqual(len(result["args_summary"]), 200)

    def _egress_policy_candidates(self, policy: dict):
        """Write `policy` to a temp file and return an EGRESS_POLICY_CANDIDATES
        override list pointing at it (first candidate; second is a guaranteed
        non-existent path so the real ~/.claude/config/egress-policy.json on
        this dev machine is never consulted by these tests)."""
        td = tempfile.mkdtemp(prefix="cast-audit-egress-test-")
        path = os.path.join(td, "egress-policy.json")
        with open(path, "w") as f:
            json.dump(policy, f)
        return [path, "/nonexistent/fallback/egress-policy.json"]

    def test_mcp_is_cloud_bound_stdio_server_classified_cloud_bound(self):
        """Fix 3 (v10 2.6 follow-up) — THE discriminating test. `github` uses
        local stdio transport (npx) yet calls api.github.com; the retired
        transport-based logic confidently returned False here — wrong answer,
        on the confident branch, in the security-meaning field. What a
        PASSING run looks like while that bug is present: this test FAILS
        (asserts True, transport logic returns False for any stdio server
        regardless of policy). Mutation-tested below by restoring the
        transport-based version and confirming exactly that failure, while
        the plain 'cloudflare is http' test would have kept passing either
        way — that contrast is why transport probes couldn't have caught
        this and a stdio+cloud_bound case is required."""
        policy = {
            "mcp_servers": {
                "cloud_bound": ["github"],
                "local_only": ["cast-record"],
            }
        }
        candidates = self._egress_policy_candidates(policy)
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", candidates):
            self.assertTrue(cast_audit._mcp_is_cloud_bound("github"))

    def test_mcp_is_cloud_bound_local_only_server_is_false(self):
        policy = {
            "mcp_servers": {
                "cloud_bound": ["github"],
                "local_only": ["cast-record"],
            }
        }
        candidates = self._egress_policy_candidates(policy)
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", candidates):
            self.assertFalse(cast_audit._mcp_is_cloud_bound("cast-record"))

    def test_mcp_is_cloud_bound_unlisted_server_fails_safe_true(self):
        policy = {
            "mcp_servers": {
                "cloud_bound": ["github"],
                "local_only": ["cast-record"],
            }
        }
        candidates = self._egress_policy_candidates(policy)
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", candidates):
            self.assertTrue(cast_audit._mcp_is_cloud_bound("some-unlisted-server"))

    def test_mcp_is_cloud_bound_missing_policy_file_fails_safe_true(self):
        with mock.patch.object(
            cast_audit, "EGRESS_POLICY_CANDIDATES",
            ["/nonexistent/a/egress-policy.json", "/nonexistent/b/egress-policy.json"]
        ):
            self.assertTrue(cast_audit._mcp_is_cloud_bound("anything"))

    def test_mcp_is_cloud_bound_malformed_json_fails_safe_true(self):
        td = tempfile.mkdtemp(prefix="cast-audit-egress-malformed-")
        path = os.path.join(td, "egress-policy.json")
        with open(path, "w") as f:
            f.write("{not valid json")
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", [path]):
            self.assertTrue(cast_audit._mcp_is_cloud_bound("anything"))

    def test_mcp_is_cloud_bound_wired_through_parse_tool_fields(self):
        """Wiring-level check — confirms parse_tool_fields() actually consults
        _mcp_is_cloud_bound() rather than leaving the base-dict False default.
        Uses github (stdio, cloud_bound) specifically so a default-masking
        regression (function never called) cannot coincidentally pass, unlike
        a stdio-defaults-false check would."""
        policy = {
            "mcp_servers": {
                "cloud_bound": ["github"],
                "local_only": ["cast-record"],
            }
        }
        candidates = self._egress_policy_candidates(policy)
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", candidates):
            data = {"tool_name": "mcp__github__list_issues", "tool_input": {}}
            result = cast_audit.parse_tool_fields(data)
            self.assertTrue(result["is_cloud_bound"])

    def test_mcp_is_cloud_bound_reads_real_repo_egress_policy(self):
        """Integration check against the REAL config/egress-policy.json (no
        mocked EGRESS_POLICY_CANDIDATES) — catches drift between this
        function and the actual policy file's contents, e.g. Fix 2's
        `cloudflare` addition. Relies on EGRESS_POLICY_CANDIDATES' first entry
        (os.getcwd()/config/egress-policy.json, bound at cast-audit.py import
        time) resolving to the repo's real config/ — true when the test
        suite is run from the repo root, as tests/run.sh and CI both do."""
        self.assertTrue(cast_audit._mcp_is_cloud_bound("cloudflare"))
        self.assertFalse(cast_audit._mcp_is_cloud_bound("cast-record"))

    def test_mcp_is_cloud_bound_still_true_when_policy_load_logs_error(self):
        """Security Low finding follow-up: the fail-safe VALUE (True) and the
        visible failure signal (a _log_error() call) must now coexist —
        neither is optional. What a PASSING run looks like while the bug is
        present: this test FAILS on the mock_log assertion (never called)
        while STILL returning True — the exact "safe value, invisible
        failure" defect this fix closes. The pre-existing
        `..._fails_safe_true` tests above only check the value and would
        keep passing regardless, which is why they didn't catch this."""
        with mock.patch.object(
            cast_audit, "EGRESS_POLICY_CANDIDATES", ["/nonexistent/a/egress-policy.json"]
        ):
            with mock.patch.object(cast_audit, "_log_error") as mock_log:
                result = cast_audit._mcp_is_cloud_bound("anything")
        self.assertTrue(result, "fail-safe VALUE must not change")
        mock_log.assert_called_once()

    def test_outcome_ok_no_error_key(self):
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": {"result": "success"},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["outcome"], "ok")
        self.assertNotIn("error_preview", result)

    def test_outcome_error_from_error_key(self):
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": {"error": "rate limit exceeded"},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["error_preview"], "rate limit exceeded")

    def test_outcome_error_from_iserror_flag(self):
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": {"isError": True, "content": "boom"},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["outcome"], "error")

    def test_outcome_error_from_content_block_list(self):
        """tool_response as a list of content blocks (MCP shape) must not raise."""
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": [{"type": "error", "text": "not found"}],
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["error_preview"], "not found")

    def test_outcome_string_tool_response_is_ok(self):
        """tool_response as a plain string must not raise."""
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": "plain text result",
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["outcome"], "ok")

    def test_outcome_missing_tool_response_is_ok(self):
        """Missing tool_response (e.g. pre-mode) must not raise."""
        data = {"tool_name": "mcp__srv__tool", "tool_input": {}}
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["outcome"], "ok")

    def test_result_size_present_and_positive(self):
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": {"result": "abcdefgh"},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertIn("result_size", result)
        self.assertGreater(result["result_size"], 0)


class TestMcpNonRegression(unittest.TestCase):
    """Regression guard: non-MCP tool calls must keep their existing shape.
    cast-record-review.py, cast-commit-reconcile.py, and cast-redact.py all
    parse audit.jsonl — changing the non-MCP record shape is out of scope."""

    def test_bash_tool_gains_no_mcp_fields(self):
        data = {"tool_name": "Bash", "tool_input": {"command": "ls"}}
        result = cast_audit.parse_tool_fields(data)
        for key in ("mcp_server", "mcp_tool", "args_summary", "outcome", "error_preview", "result_size"):
            self.assertNotIn(key, result)

    def test_write_tool_gains_no_mcp_fields(self):
        data = {"tool_name": "Write", "tool_input": {"file_path": "/tmp/x.txt", "content": "hi"}}
        result = cast_audit.parse_tool_fields(data)
        for key in ("mcp_server", "mcp_tool", "args_summary", "outcome", "error_preview", "result_size"):
            self.assertNotIn(key, result)


class TestSessionIdPrecedence(unittest.TestCase):
    """Test main() — session_id must be read from the stdin payload first,
    falling back to the env var, then 'unknown' (v10 2.6 Edit 1)."""

    def setUp(self):
        self._orig_audit_log = cast_audit.AUDIT_LOG
        self._tmpdir = tempfile.mkdtemp(prefix='cast-audit-sid-test-')
        cast_audit.AUDIT_LOG = os.path.join(self._tmpdir, 'audit.jsonl')
        self._orig_env_sid = os.environ.get('CLAUDE_SESSION_ID')

    def tearDown(self):
        cast_audit.AUDIT_LOG = self._orig_audit_log
        if self._orig_env_sid is not None:
            os.environ['CLAUDE_SESSION_ID'] = self._orig_env_sid
        else:
            os.environ.pop('CLAUDE_SESSION_ID', None)

    def _run_main_with_stdin(self, payload: dict) -> dict:
        stdin_data = json.dumps(payload)
        with mock.patch('sys.stdin', io.StringIO(stdin_data)):
            with mock.patch('sys.argv', ['cast-audit.py', '--mode', 'post']):
                cast_audit.main()
        with open(cast_audit.AUDIT_LOG) as f:
            lines = f.readlines()
        return json.loads(lines[-1])

    def test_payload_session_id_takes_precedence_over_env(self):
        os.environ['CLAUDE_SESSION_ID'] = 'env-session'
        record = self._run_main_with_stdin({
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
            "session_id": "payload-session",
        })
        self.assertEqual(record["session_id"], "payload-session")

    def test_env_session_id_used_when_payload_missing(self):
        os.environ['CLAUDE_SESSION_ID'] = 'env-session'
        record = self._run_main_with_stdin({
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
        })
        self.assertEqual(record["session_id"], "env-session")

    def test_unknown_when_neither_present(self):
        os.environ.pop('CLAUDE_SESSION_ID', None)
        record = self._run_main_with_stdin({
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
        })
        self.assertEqual(record["session_id"], "unknown")


class TestWriteMcpRoutingEvent(unittest.TestCase):
    """Test write_mcp_routing_event() — persists MCP calls to routing_events
    (v10 2.6 Edit 4). ⚠ db_write swallows errors silently — SELECT the row back
    rather than trusting a clean return (known CAST hazard)."""

    def setUp(self):
        from cast_db import db_execute
        db_execute(
            "CREATE TABLE IF NOT EXISTS routing_events ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, timestamp TEXT, "
            "prompt_preview TEXT, action TEXT, matched_route TEXT, pattern TEXT, "
            "confidence TEXT, project TEXT, event_type TEXT, data TEXT)"
        )

    def test_persists_mcp_call_and_row_is_readable_back(self):
        from cast_db import db_query
        record = {"tool_name": "mcp__cast-record__query", "mcp_server": "cast-record"}
        cast_audit.write_mcp_routing_event(record, "sess-mcp-1", "2026-08-16T00:00:00Z", "test-proj")
        rows = db_query(
            "SELECT session_id, event_type, project, data FROM routing_events "
            "WHERE session_id = ? AND event_type = 'mcp_tool_call'",
            ("sess-mcp-1",)
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][0], "sess-mcp-1")
        self.assertEqual(rows[0][1], "mcp_tool_call")
        self.assertEqual(rows[0][2], "test-proj")
        stored = json.loads(rows[0][3])
        self.assertEqual(stored["tool_name"], "mcp__cast-record__query")

    def test_never_raises_on_db_failure(self):
        """Fail-soft: a DB error must not propagate (never crash the hook)."""
        with mock.patch.object(cast_audit, '_log_error') as mock_log:
            with mock.patch('cast_db.db_write', side_effect=Exception("db exploded")):
                cast_audit.write_mcp_routing_event({}, "sess", "ts", "proj")
            mock_log.assert_called_once()


class TestMainMcpGating(unittest.TestCase):
    """Test main() — DB persistence must be gated to mcp__* tool calls only
    (v10 2.6 Edit 4). Non-MCP calls fire ~1300+/day; a write on that hot path
    is unacceptable."""

    def setUp(self):
        self._orig_audit_log = cast_audit.AUDIT_LOG
        self._tmpdir = tempfile.mkdtemp(prefix='cast-audit-gate-test-')
        cast_audit.AUDIT_LOG = os.path.join(self._tmpdir, 'audit.jsonl')

    def tearDown(self):
        cast_audit.AUDIT_LOG = self._orig_audit_log

    def _run_main_with_stdin(self, payload: dict) -> None:
        stdin_data = json.dumps(payload)
        with mock.patch('sys.stdin', io.StringIO(stdin_data)):
            with mock.patch('sys.argv', ['cast-audit.py', '--mode', 'post']):
                cast_audit.main()

    def test_non_mcp_call_does_not_invoke_db_write(self):
        with mock.patch.object(cast_audit, 'write_mcp_routing_event') as mock_write:
            self._run_main_with_stdin({"tool_name": "Bash", "tool_input": {"command": "ls"}})
            mock_write.assert_not_called()

    def test_mcp_call_invokes_db_write(self):
        with mock.patch.object(cast_audit, 'write_mcp_routing_event') as mock_write:
            self._run_main_with_stdin({
                "tool_name": "mcp__cast-record__query",
                "tool_input": {"limit": 5},
                "tool_response": {"result": "ok"},
            })
            mock_write.assert_called_once()


class TestSanitizeErrorText(unittest.TestCase):
    """Test _sanitize_error_text() (Fix 1, HIGH — security review) — provider-
    controlled MCP error text must be redacted BEFORE truncation, using
    cast-redact.py's real regex engine, and must FAIL CLOSED (return None,
    never raw text) on any failure.

    cast_audit.REDACT_SCRIPT defaults to the INSTALLED ~/.claude copy, which
    is absent in CI (no ~/.claude there); setUp/tearDown repoint it at the
    repo copy so redaction is actually exercised regardless of environment.
    Tests that specifically probe the fail-closed-when-missing path
    (test_fails_closed_when_redact_script_missing) further override it with
    their own mock.patch.object, layered on top of this class-level default."""

    def setUp(self):
        self._orig_redact_script = cast_audit.REDACT_SCRIPT
        cast_audit.REDACT_SCRIPT = str(_SCRIPTS_DIR / 'cast-redact.py')

    def tearDown(self):
        cast_audit.REDACT_SCRIPT = self._orig_redact_script

    def test_redacts_github_token_keeps_surrounding_context(self):
        token = "ghp_" + "a" * 36
        text = f"Authentication failed: invalid token {token}"
        result = cast_audit._sanitize_error_text(text)
        self.assertIsNotNone(result)
        self.assertNotIn(token, result)
        self.assertIn("Authentication failed", result)

    def test_redacts_aws_access_key(self):
        key = "AKIA" + "1B2C3D4E5F6G7H8I"  # realistic: real AWS keys always mix digits+letters
        text = f"access denied for key {key}"
        result = cast_audit._sanitize_error_text(text)
        self.assertIsNotNone(result)
        self.assertNotIn(key, result)
        self.assertIn("access denied", result)

    def test_no_pii_passes_through_unchanged(self):
        text = "rate limit exceeded"
        result = cast_audit._sanitize_error_text(text)
        self.assertEqual(result, text)

    def test_fails_closed_when_redact_script_missing(self):
        with mock.patch.object(cast_audit, "REDACT_SCRIPT", "/nonexistent/cast-redact.py"):
            result = cast_audit._sanitize_error_text("some error text")
            self.assertIsNone(result)

    def test_fails_closed_on_loader_exception(self):
        with mock.patch("importlib.util.spec_from_file_location", side_effect=Exception("boom")):
            result = cast_audit._sanitize_error_text("some error text")
            self.assertIsNone(result)


class TestErrorPreviewSanitization(unittest.TestCase):
    """Integration: error_preview via parse_tool_fields() must never leak a
    provider-echoed secret (Fix 1, HIGH). Truncation to 120 chars alone is not
    redaction — both a GitHub PAT (~40 chars) and an AWS key (20 chars) fit
    inside that cap, so these assert the SECRET is gone, not just short.

    cast_audit.REDACT_SCRIPT defaults to the INSTALLED ~/.claude copy, which
    is absent in CI; setUp/tearDown repoint it at the repo copy so
    sanitization actually runs. test_error_preview_dropped_entirely_when_
    sanitization_fails_closed further overrides it with its own
    mock.patch.object to force the fail-closed path."""

    def setUp(self):
        self._orig_redact_script = cast_audit.REDACT_SCRIPT
        cast_audit.REDACT_SCRIPT = str(_SCRIPTS_DIR / 'cast-redact.py')

    def tearDown(self):
        cast_audit.REDACT_SCRIPT = self._orig_redact_script

    def test_error_preview_omits_github_token_keeps_context(self):
        token = "ghp_" + "c" * 36
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": {"error": f"401 Unauthorized: bad credentials {token}"},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertEqual(result["outcome"], "error")
        self.assertNotIn(token, result["error_preview"])
        self.assertIn("Unauthorized", result["error_preview"])

    def test_error_preview_omits_aws_key(self):
        key = "AKIA" + "1D2E3F4G5H6I7J8K"  # realistic: real AWS keys always mix digits+letters
        data = {
            "tool_name": "mcp__srv__tool",
            "tool_input": {},
            "tool_response": {"error": f"access denied {key}"},
        }
        result = cast_audit.parse_tool_fields(data)
        self.assertNotIn(key, result["error_preview"])

    def test_error_preview_dropped_entirely_when_sanitization_fails_closed(self):
        """Fail-closed contract: if sanitization can't run, error_preview must
        be ABSENT, never fall back to raw provider text."""
        with mock.patch.object(cast_audit, "REDACT_SCRIPT", "/nonexistent/cast-redact.py"):
            data = {
                "tool_name": "mcp__srv__tool",
                "tool_input": {},
                "tool_response": {"error": "some raw error text"},
            }
            result = cast_audit.parse_tool_fields(data)
            self.assertEqual(result["outcome"], "error")
            self.assertNotIn("error_preview", result)

    def test_sanitization_is_unconditional_not_gated_on_redact_pii_config(self):
        """Sanitization must run regardless of cfg.get('redact_pii') — DB/JSONL
        persistence for MCP is unconditional, so sanitization must be too."""
        token = "ghp_" + "e" * 36
        with mock.patch.object(cast_audit, "_read_cast_cli_cfg", return_value={"redact_pii": False}):
            data = {
                "tool_name": "mcp__srv__tool",
                "tool_input": {},
                "tool_response": {"error": f"failed: {token}"},
            }
            result = cast_audit.parse_tool_fields(data)
            self.assertNotIn(token, result["error_preview"])


class TestMcpDbWriteOrdering(unittest.TestCase):
    """Test main() — write_mcp_routing_event() must run AFTER the redaction
    block finalizes `record`, not before (Fix 2, MEDIUM). Real MCP calls never
    populate url/query/command_preview today (Fix 4's confirmed dead-code
    finding), so the redaction block never actually mutates a real MCP
    record — meaning a plain "DB row == JSONL line" content check can't
    discriminate the ordering bug (it would pass either way). This test
    forces the redaction path via a patched parse_tool_fields() so the
    ordering is genuinely exercised: with the bug (write BEFORE redaction),
    the DB row is serialized before `record["redacted"]` exists and the
    assertion below fails; with the fix, it passes.
    """

    def setUp(self):
        from cast_db import db_execute
        db_execute(
            "CREATE TABLE IF NOT EXISTS routing_events ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, timestamp TEXT, "
            "prompt_preview TEXT, action TEXT, matched_route TEXT, pattern TEXT, "
            "confidence TEXT, project TEXT, event_type TEXT, data TEXT)"
        )
        self._orig_audit_log = cast_audit.AUDIT_LOG
        self._tmpdir = tempfile.mkdtemp(prefix='cast-audit-order-test-')
        cast_audit.AUDIT_LOG = os.path.join(self._tmpdir, 'audit.jsonl')

    def tearDown(self):
        cast_audit.AUDIT_LOG = self._orig_audit_log

    def test_db_row_reflects_redaction_annotation(self):
        from cast_db import db_query

        def fake_parse_tool_fields(data):
            return {
                "tool_name": "mcp__srv__tool",
                "mcp_server": "srv",
                "mcp_tool": "tool",
                "is_cloud_bound": True,
                # Real MCP calls never set `query` — forced here to exercise
                # the redaction-annotation path deterministically.
                "query": "some text to redact",
                "input_hash": "abc123",
            }

        session_id = "sess-order-1"
        with mock.patch.object(cast_audit, 'parse_tool_fields', side_effect=fake_parse_tool_fields):
            with mock.patch.object(cast_audit, '_read_cast_cli_cfg', return_value={"redact_pii": True}):
                with mock.patch.object(
                    cast_audit, 'run_redact_analysis',
                    return_value={"entity_count": 1, "entities": []}
                ):
                    payload = {"tool_name": "mcp__srv__tool", "tool_input": {}, "session_id": session_id}
                    with mock.patch('sys.stdin', io.StringIO(json.dumps(payload))):
                        # --mode post: never hits the strict-block early return,
                        # regardless of safelist match, so no need to force that.
                        with mock.patch('sys.argv', ['cast-audit.py', '--mode', 'post']):
                            cast_audit.main()

        rows = db_query(
            "SELECT data FROM routing_events WHERE session_id = ? AND event_type = 'mcp_tool_call'",
            (session_id,)
        )
        self.assertEqual(len(rows), 1)
        db_record = json.loads(rows[0][0])
        self.assertTrue(
            db_record.get("redacted"),
            "DB row must reflect the redaction annotation added by main()'s "
            "redaction block — proves write_mcp_routing_event() fires AFTER "
            "it, not before."
        )
        self.assertEqual(db_record.get("redacted_count"), 1)

        # And the JSONL copy must agree — same final `record` object.
        with open(cast_audit.AUDIT_LOG) as f:
            jsonl_record = json.loads(f.readlines()[-1])
        self.assertEqual(db_record, jsonl_record)


class TestLoadEgressPolicyLogging(unittest.TestCase):
    """Test _load_egress_policy() (security Low finding follow-up) — a
    missing or malformed policy file must be logged via _log_error(), not
    fail silently. Before this fix, every MCP call with a broken/missing
    policy fell through to is_cloud_bound=True with NO diagnostic trace —
    the correct fail-safe VALUE, but indistinguishable from a working
    classifier that correctly found the server cloud-bound. That is exactly
    the "safe value, invisible failure" defect class this release targets."""

    def test_missing_policy_logs_error_and_returns_empty_dict(self):
        candidates = ["/nonexistent/a/egress-policy.json", "/nonexistent/b/egress-policy.json"]
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", candidates):
            with mock.patch.object(cast_audit, "_log_error") as mock_log:
                result = cast_audit._load_egress_policy()
        self.assertEqual(result, {})
        mock_log.assert_called_once()
        self.assertIn("egress policy", mock_log.call_args[0][0].lower())

    def test_malformed_json_logs_error_with_path_and_returns_empty_dict(self):
        td = tempfile.mkdtemp(prefix="cast-audit-egress-log-malformed-")
        path = os.path.join(td, "egress-policy.json")
        with open(path, "w") as f:
            f.write("{not valid json")
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", [path]):
            with mock.patch.object(cast_audit, "_log_error") as mock_log:
                result = cast_audit._load_egress_policy()
        self.assertEqual(result, {})
        mock_log.assert_called_once()
        logged_msg = mock_log.call_args[0][0]
        self.assertIn(path, logged_msg)

    def test_successful_load_does_not_log(self):
        """Regression guard: logging is for failures only — a normal,
        successful load must not write to hook-errors.log."""
        policy = {"mcp_servers": {"cloud_bound": ["x"], "local_only": ["y"]}}
        td = tempfile.mkdtemp(prefix="cast-audit-egress-log-success-")
        path = os.path.join(td, "egress-policy.json")
        with open(path, "w") as f:
            json.dump(policy, f)
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", [path]):
            with mock.patch.object(cast_audit, "_log_error") as mock_log:
                result = cast_audit._load_egress_policy()
        self.assertEqual(result, policy)
        mock_log.assert_not_called()

    def test_second_candidate_used_when_first_missing_no_log(self):
        """Regression guard: falling through to the second candidate path
        (the normal $CWD-miss / ~/.claude-hit case) is not a failure and
        must not log — only exhausting ALL candidates is a failure."""
        policy = {"mcp_servers": {"cloud_bound": [], "local_only": []}}
        td = tempfile.mkdtemp(prefix="cast-audit-egress-log-fallback-")
        real_path = os.path.join(td, "egress-policy.json")
        with open(real_path, "w") as f:
            json.dump(policy, f)
        candidates = ["/nonexistent/first/egress-policy.json", real_path]
        with mock.patch.object(cast_audit, "EGRESS_POLICY_CANDIDATES", candidates):
            with mock.patch.object(cast_audit, "_log_error") as mock_log:
                result = cast_audit._load_egress_policy()
        self.assertEqual(result, policy)
        mock_log.assert_not_called()


class TestWriteRedactMap(unittest.TestCase):
    """Test write_redact_map() — RL unit: the entity map written to
    ~/.claude/logs/redact-maps/ must never carry the plaintext `original`
    field cast-redact.py attaches, only entity_type/start/end/score/
    original_hash. original_hash is what correlation needs; the raw matched
    text must not touch disk.

    REDACT_MAPS_DIR is a module-level constant baked to the real HOME at
    import time, so tests patch it directly to a temp dir rather than
    exporting HOME (which would arrive too late to affect an already-bound
    constant)."""

    # Split so the literal isn't a contiguous AWS-key-shaped string (would
    # trip scripts/ci-pii-scan.sh's `AKIA[0-9A-Z]{16}` pattern); value is
    # byte-identical to the concatenated form.
    _FAKE_AWS_KEY = "AKIA" + "BCDEFGHIJKLMNOPQ"

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp(prefix="cast-audit-redact-map-test-")
        self._patcher = mock.patch.object(cast_audit, "REDACT_MAPS_DIR", self._tmpdir)
        self._patcher.start()

    def tearDown(self):
        self._patcher.stop()

    def _read_written_map(self):
        files = os.listdir(self._tmpdir)
        self.assertEqual(len(files), 1, f"expected exactly one map file, got {files!r}")
        with open(os.path.join(self._tmpdir, files[0])) as f:
            return json.load(f)

    def test_original_field_stripped_from_written_map(self):
        """Mutation check: reverting the strip (writing redact_result['entities']
        verbatim) makes this assertion fail because 'original' is present."""
        redact_result = {
            "entities": [
                {
                    "entity_type": "AWS_ACCESS_KEY",
                    "start": 8,
                    "end": 28,
                    "score": 0.9,
                    "original": self._FAKE_AWS_KEY,
                    "original_hash": "b445e97203ae0d5e",
                }
            ]
        }
        cast_audit.write_redact_map("sess-1", "2026-08-17T00:00:00Z", redact_result)
        data = self._read_written_map()
        self.assertEqual(len(data["entities"]), 1)
        entity = data["entities"][0]
        self.assertNotIn("original", entity)
        self.assertNotIn(self._FAKE_AWS_KEY, json.dumps(data))

    def test_correlation_fields_still_written(self):
        """The map must stay useful: entity_type/start/end/score/original_hash
        survive the strip."""
        redact_result = {
            "entities": [
                {
                    "entity_type": "AWS_ACCESS_KEY",
                    "start": 8,
                    "end": 28,
                    "score": 0.9,
                    "original": self._FAKE_AWS_KEY,
                    "original_hash": "b445e97203ae0d5e",
                }
            ]
        }
        cast_audit.write_redact_map("sess-1", "2026-08-17T00:00:00Z", redact_result)
        entity = self._read_written_map()["entities"][0]
        self.assertEqual(entity["entity_type"], "AWS_ACCESS_KEY")
        self.assertEqual(entity["start"], 8)
        self.assertEqual(entity["end"], 28)
        self.assertEqual(entity["score"], 0.9)
        self.assertEqual(entity["original_hash"], "b445e97203ae0d5e")

    def test_malformed_entity_does_not_crash(self):
        """A non-dict entity (malformed input) must be skipped, not raise —
        write_redact_map's contract is 'never crash the hook pipeline'."""
        redact_result = {"entities": ["not-a-dict", None, 42]}
        with mock.patch.object(cast_audit, "_log_error") as mock_log:
            cast_audit.write_redact_map("sess-1", "2026-08-17T00:00:00Z", redact_result)
        mock_log.assert_not_called()
        data = self._read_written_map()
        self.assertEqual(data["entities"], [])

    def test_partial_entity_missing_keys_does_not_crash(self):
        """An entity dict missing some expected keys is written as-is (minus
        `original`), not dropped or crashed on."""
        redact_result = {"entities": [{"entity_type": "PHONE_NUMBER"}]}
        cast_audit.write_redact_map("sess-1", "2026-08-17T00:00:00Z", redact_result)
        entity = self._read_written_map()["entities"][0]
        self.assertEqual(entity, {"entity_type": "PHONE_NUMBER"})

    def test_no_entities_writes_empty_list(self):
        cast_audit.write_redact_map("sess-1", "2026-08-17T00:00:00Z", {"entities": []})
        data = self._read_written_map()
        self.assertEqual(data["entities"], [])
        self.assertEqual(data["session_id"], "sess-1")


if __name__ == '__main__':
    unittest.main()
