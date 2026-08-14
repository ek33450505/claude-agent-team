#!/usr/bin/env python3
"""
Unit tests for pure helpers in scripts/cast-record-review.py.

Covers:
  - get_db_path(cli_db='') — precedence: cli > CAST_DB_URL > CAST_DB_PATH > default
  - table_exists(conn, name) — checks sqlite_master for table presence
  - safe_query(conn, sql, params=()) — returns list of dicts; [] on error
  - parse_agent_max_turns(agents_dir, agent_name) — extracts maxTurns: N from YAML frontmatter
"""

import importlib.util
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_SCRIPT_PATH = _SCRIPTS_DIR / 'cast-record-review.py'

# Load module via importlib (hyphenated name cannot be imported normally)
# Set CAST_DB_PATH to a temp location first to avoid any import-time path resolution issues.
# Use mkdtemp (secure 0700 dir) + a joined name rather than the deprecated, race-prone mktemp.
os.environ['CAST_DB_PATH'] = os.path.join(tempfile.mkdtemp(prefix='cast-rr-test-'), 'cast.db')
_spec = importlib.util.spec_from_file_location('cast_record_review', str(_SCRIPT_PATH))
cast_record_review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cast_record_review)


class TestGetDbPath(unittest.TestCase):
    """Test get_db_path() precedence: cli > CAST_DB_URL > CAST_DB_PATH > default."""

    def setUp(self):
        """Save original env vars before each test."""
        self.orig_url = os.environ.get('CAST_DB_URL')
        self.orig_path = os.environ.get('CAST_DB_PATH')
        # Clear them for clean tests
        os.environ.pop('CAST_DB_URL', None)
        os.environ.pop('CAST_DB_PATH', None)

    def tearDown(self):
        """Restore original env vars."""
        if self.orig_url:
            os.environ['CAST_DB_URL'] = self.orig_url
        else:
            os.environ.pop('CAST_DB_URL', None)
        if self.orig_path:
            os.environ['CAST_DB_PATH'] = self.orig_path
        else:
            os.environ.pop('CAST_DB_PATH', None)

    def test_cli_arg_takes_precedence(self):
        """CLI arg should take highest precedence."""
        os.environ['CAST_DB_URL'] = 'sqlite:////tmp/url.db'
        os.environ['CAST_DB_PATH'] = '/tmp/path.db'
        result = cast_record_review.get_db_path('/x/cli.db')
        self.assertEqual(result, '/x/cli.db')

    def test_cast_db_url_with_sqlite_prefix(self):
        """CAST_DB_URL with sqlite:/// prefix should be stripped."""
        os.environ['CAST_DB_URL'] = 'sqlite:////tmp/u.db'
        result = cast_record_review.get_db_path('')
        self.assertEqual(result, '/tmp/u.db')

    def test_cast_db_url_beats_path(self):
        """CAST_DB_URL should beat CAST_DB_PATH when both set."""
        os.environ['CAST_DB_URL'] = 'sqlite:////tmp/url.db'
        os.environ['CAST_DB_PATH'] = '/tmp/path.db'
        result = cast_record_review.get_db_path('')
        self.assertEqual(result, '/tmp/url.db')

    def test_cast_db_path_when_no_url(self):
        """CAST_DB_PATH should be used when URL is not set."""
        os.environ['CAST_DB_PATH'] = '/tmp/p.db'
        result = cast_record_review.get_db_path('')
        self.assertEqual(result, '/tmp/p.db')

    def test_default_home_path(self):
        """Default should be ~/.claude/cast.db when nothing is set."""
        result = cast_record_review.get_db_path('')
        expected = os.path.expanduser('~/.claude/cast.db')
        self.assertEqual(result, expected)

    def test_empty_cast_db_url_falls_through(self):
        """Empty CAST_DB_URL should fall through to CAST_DB_PATH."""
        os.environ['CAST_DB_URL'] = ''
        os.environ['CAST_DB_PATH'] = '/tmp/p.db'
        result = cast_record_review.get_db_path('')
        self.assertEqual(result, '/tmp/p.db')


class TestTableExists(unittest.TestCase):
    """Test table_exists() with an in-memory SQLite database."""

    def setUp(self):
        """Create an in-memory SQLite connection for each test."""
        self.conn = sqlite3.connect(':memory:')

    def tearDown(self):
        """Close the connection."""
        self.conn.close()

    def test_table_exists_returns_true(self):
        """Should return True for an existing table."""
        self.conn.execute('CREATE TABLE foo(id INTEGER, name TEXT)')
        result = cast_record_review.table_exists(self.conn, 'foo')
        self.assertTrue(result)

    def test_table_exists_returns_false_for_missing_table(self):
        """Should return False for a nonexistent table."""
        result = cast_record_review.table_exists(self.conn, 'missing')
        self.assertFalse(result)

    def test_table_exists_multiple_tables(self):
        """Should correctly identify tables in a database with multiple tables."""
        self.conn.execute('CREATE TABLE table1(x INTEGER)')
        self.conn.execute('CREATE TABLE table2(y TEXT)')
        self.assertTrue(cast_record_review.table_exists(self.conn, 'table1'))
        self.assertTrue(cast_record_review.table_exists(self.conn, 'table2'))
        self.assertFalse(cast_record_review.table_exists(self.conn, 'table3'))


class TestSafeQuery(unittest.TestCase):
    """Test safe_query() — returns list of dicts, empty list on error."""

    def setUp(self):
        """Create an in-memory SQLite connection with a test table."""
        self.conn = sqlite3.connect(':memory:')
        self.conn.execute('''
            CREATE TABLE test_table (
                id INTEGER PRIMARY KEY,
                name TEXT,
                value REAL
            )
        ''')
        self.conn.execute("INSERT INTO test_table (name, value) VALUES ('alice', 1.5)")
        self.conn.execute("INSERT INTO test_table (name, value) VALUES ('bob', 2.5)")
        self.conn.commit()

    def tearDown(self):
        """Close the connection."""
        self.conn.close()

    def test_valid_select_returns_list_of_dicts(self):
        """Valid SELECT should return a list of dicts with column names as keys."""
        result = cast_record_review.safe_query(self.conn, 'SELECT * FROM test_table')
        self.assertIsInstance(result, list)
        self.assertEqual(len(result), 2)
        # First row
        self.assertIsInstance(result[0], dict)
        self.assertIn('id', result[0])
        self.assertIn('name', result[0])
        self.assertIn('value', result[0])
        self.assertEqual(result[0]['name'], 'alice')
        self.assertAlmostEqual(result[0]['value'], 1.5)

    def test_select_with_params(self):
        """SELECT with parameters should work correctly."""
        result = cast_record_review.safe_query(
            self.conn,
            'SELECT * FROM test_table WHERE name = ?',
            ('bob',)
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['name'], 'bob')

    def test_nonexistent_table_returns_empty_list(self):
        """Query against nonexistent table should return [] (not raise)."""
        result = cast_record_review.safe_query(
            self.conn,
            'SELECT * FROM nonexistent_table'
        )
        self.assertEqual(result, [])

    def test_syntax_error_returns_empty_list(self):
        """Invalid SQL syntax should return [] (not raise)."""
        result = cast_record_review.safe_query(
            self.conn,
            'SELECCT * FROM test_table'  # typo
        )
        self.assertEqual(result, [])

    def test_empty_result_set(self):
        """A valid query with no matching rows should return empty list."""
        result = cast_record_review.safe_query(
            self.conn,
            'SELECT * FROM test_table WHERE name = ?',
            ('nonexistent',)
        )
        self.assertEqual(result, [])


class TestParseAgentMaxTurns(unittest.TestCase):
    """Test parse_agent_max_turns() — extracts maxTurns from YAML frontmatter."""

    def setUp(self):
        """Create a temporary directory for test agent files."""
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_parses_maxturns_from_frontmatter(self):
        """Should extract maxTurns: N from frontmatter."""
        agent_file = os.path.join(self.tmpdir, 'test-agent.md')
        with open(agent_file, 'w') as f:
            f.write('''---
name: test-agent
description: Test agent
maxTurns: 42
skills: []
---
# Agent definition
Some content here.
''')
        result = cast_record_review.parse_agent_max_turns(self.tmpdir, 'test-agent')
        self.assertEqual(result, 42)

    def test_returns_none_when_maxturns_missing(self):
        """Should return None when maxTurns line is absent from frontmatter."""
        agent_file = os.path.join(self.tmpdir, 'no-turns.md')
        with open(agent_file, 'w') as f:
            f.write('''---
name: no-turns
description: No maxTurns defined
skills: []
---
# Agent
Content here.
''')
        result = cast_record_review.parse_agent_max_turns(self.tmpdir, 'no-turns')
        self.assertIsNone(result)

    def test_returns_none_when_file_missing(self):
        """Should return None when the agent file does not exist."""
        result = cast_record_review.parse_agent_max_turns(self.tmpdir, 'missing-agent')
        self.assertIsNone(result)

    def test_returns_none_when_no_frontmatter(self):
        """Should return None when file has no --- frontmatter delimiters."""
        agent_file = os.path.join(self.tmpdir, 'no-frontmatter.md')
        with open(agent_file, 'w') as f:
            f.write('# Just content\nNo frontmatter here.')
        result = cast_record_review.parse_agent_max_turns(self.tmpdir, 'no-frontmatter')
        self.assertIsNone(result)

    def test_parses_maxturns_with_whitespace(self):
        """Should handle various whitespace around maxTurns value."""
        agent_file = os.path.join(self.tmpdir, 'whitespace.md')
        with open(agent_file, 'w') as f:
            f.write('''---
maxTurns:   50
---
Content
''')
        result = cast_record_review.parse_agent_max_turns(self.tmpdir, 'whitespace')
        self.assertEqual(result, 50)

    def test_maxturns_appears_in_body_not_frontmatter(self):
        """If maxTurns appears in body (not frontmatter), should return None."""
        agent_file = os.path.join(self.tmpdir, 'body-maxturns.md')
        with open(agent_file, 'w') as f:
            f.write('''---
name: test
---
# Content
maxTurns: 99
This is in the body, not frontmatter.
''')
        result = cast_record_review.parse_agent_max_turns(self.tmpdir, 'body-maxturns')
        # Should return None because the regex only looks in frontmatter (parts[1])
        self.assertIsNone(result)


class TestSectionStaleMemories(unittest.TestCase):
    """Test section_stale_memories() — reuses cast-stale-memories.py via subprocess.

    Each test points repo_root at a temp dir with a stub scripts/cast-stale-memories.py
    so scanner output is fully controlled and deterministic, without touching real
    ~/.claude/projects or depending on the real scanner's own file-scanning logic
    (that logic has its own dedicated coverage in tests/cast-stale-memories.bats).
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix='cast-rr-stale-test-')
        self.scripts_dir = os.path.join(self.tmpdir, 'scripts')
        os.makedirs(self.scripts_dir)
        self.stub_path = os.path.join(self.scripts_dir, 'cast-stale-memories.py')

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_stub(self, content):
        with open(self.stub_path, 'w') as f:
            f.write(content)

    def test_zero_stale_renders_ok(self):
        """0 stale -> 'OK' header, explicit '0 stale memories' line, no proposals."""
        self._write_stub("print(0)\n")
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: OK", text)
        self.assertIn("0 stale memories", text)
        self.assertEqual(proposals, [])

    def test_watch_with_entries_lists_files_and_proposes(self):
        """N stale entries -> 'WATCH' header, all filenames listed, one Proposal."""
        stub = (
            "print(3)\n"
            "print('/fake/proj/memory/a.md|2026-06-01|74')\n"
            "print('/fake/proj/memory/b.md|2026-06-05|70')\n"
            "print('/fake/proj/memory/c.md|2026-06-10|65')\n"
        )
        self._write_stub(stub)
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: WATCH", text)
        self.assertIn("a.md", text)
        self.assertIn("b.md", text)
        self.assertIn("c.md", text)
        self.assertIn("3 stale memories flagged", text)
        self.assertEqual(len(proposals), 1)
        self.assertEqual(proposals[0].section, "5. Stale Memories")
        self.assertIn("3 auto-memories", proposals[0].title)

    def test_caps_at_ten_and_states_omitted_count(self):
        """>10 entries -> only top 10 by age shown, omitted count stated, none silently dropped."""
        rows = "\n".join(
            f"print('/fake/proj/memory/entry{i}.md|2026-06-01|{100 - i}')" for i in range(15)
        )
        self._write_stub("print(15)\n" + rows + "\n")
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: WATCH", text)
        self.assertIn("top 10 by age shown", text)
        self.assertIn("5 omitted", text)
        # Oldest 10 (entry0..entry9, ages 100..91) shown; entry10+ (ages 90..86) omitted.
        self.assertIn("entry0.md", text)
        self.assertIn("entry9.md", text)
        self.assertNotIn("entry10.md", text)
        self.assertEqual(len(proposals), 1)

    def test_watch_notes_partial_parse_mismatch(self):
        """Some body rows unparseable but not all -> WATCH with an explicit mismatch note."""
        stub = (
            "print(3)\n"
            "print('/fake/proj/memory/a.md|2026-06-01|74')\n"
            "print('garbage-row-no-pipes')\n"
            "print('/fake/proj/memory/b.md|2026-06-05|70')\n"
        )
        self._write_stub(stub)
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: WATCH", text)
        self.assertIn("scanner reported 3 but only 2 entries were", text)
        self.assertEqual(len(proposals), 1)

    def test_degraded_when_scanner_missing(self):
        """Scanner file absent -> DEGRADED text, never a false '0 stale'."""
        # scripts/ exists (setUp) but cast-stale-memories.py was never written.
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: DEGRADED", text)
        self.assertIn("Could not check", text)
        self.assertIn("scanner not found", text)
        self.assertNotIn("0 stale memories", text)
        self.assertEqual(proposals, [])

    def test_degraded_when_scanner_exits_nonzero(self):
        """Scanner crashes (nonzero exit) -> DEGRADED, never a false '0 stale'."""
        self._write_stub("import sys\nprint('boom', file=sys.stderr)\nsys.exit(1)\n")
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: DEGRADED", text)
        self.assertIn("Could not check", text)
        self.assertIn("exited 1", text)
        self.assertNotIn("0 stale memories", text)
        self.assertEqual(proposals, [])

    def test_degraded_when_count_line_not_integer(self):
        """Malformed count line -> DEGRADED, never a false '0 stale'."""
        self._write_stub("print('not-a-number')\n")
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: DEGRADED", text)
        self.assertIn("Could not check", text)
        self.assertNotIn("0 stale memories", text)
        self.assertEqual(proposals, [])

    def test_degraded_when_count_positive_but_no_parseable_rows(self):
        """Count > 0 but every body row is garbage -> DEGRADED, not a silent '0 shown'."""
        self._write_stub("print(2)\nprint('garbage-row-no-pipes')\n")
        text, proposals = cast_record_review.section_stale_memories(self.tmpdir)
        self.assertIn("### Stale auto-memories: DEGRADED", text)
        self.assertIn("0 parseable entries", text)
        self.assertEqual(proposals, [])


if __name__ == '__main__':
    unittest.main()
