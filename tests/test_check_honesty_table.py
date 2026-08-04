#!/usr/bin/env python3
"""
Unit tests for scripts/eval-graders/check-honesty-table.py.

Covers:
  - SQL injection allowlist validation (--table must be in ALLOWED_TABLES)
  - Database and table existence checks
  - Row counting with verified column logic
  - --since timestamp filtering
  - Exit codes (0 for pass, 1 for fail, 2 for error/skip)
"""

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts' / 'eval-graders'
_SCRIPT_PATH = _SCRIPTS_DIR / 'check-honesty-table.py'


class TestCheckHonestTableAllowlist(unittest.TestCase):
    """Test SQL injection allowlist validation."""

    def setUp(self):
        """Create a temp directory and mock DB path."""
        self.tmpdir = tempfile.mkdtemp(prefix='honesty-test-')
        self.db_path = os.path.join(self.tmpdir, 'cast.db')
        # Create a minimal DB with one allowed table
        conn = sqlite3.connect(self.db_path)
        conn.execute('CREATE TABLE agent_protocol_violations(agent_id TEXT, timestamp TEXT)')
        conn.commit()
        conn.close()

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_rejects_table_not_in_allowlist(self):
        """--table value not in ALLOWED_TABLES should exit 2."""
        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'not_a_real_table',
             '--match-value', 'x'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn('not in allowlist', result.stdout)

    def test_accepts_agent_protocol_violations_table(self):
        """agent_protocol_violations should be allowed."""
        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_protocol_violations',
             '--match-value', 'test-agent'],
            capture_output=True,
            text=True,
            env=env
        )
        # Should pass or fail on query logic, not allowlist rejection
        self.assertIn('agent_protocol_violations', result.stdout)

    def test_accepts_agent_hallucinations_table(self):
        """agent_hallucinations should be allowed."""
        tmpdir = tempfile.mkdtemp(prefix='honesty-test-')
        db_path = os.path.join(tmpdir, 'cast.db')
        conn = sqlite3.connect(db_path)
        conn.execute('CREATE TABLE agent_hallucinations(agent_name TEXT, timestamp TEXT, verified INTEGER)')
        conn.commit()
        conn.close()

        try:
            env = os.environ.copy()
            env['CAST_DB_PATH'] = db_path
            result = subprocess.run(
                [sys.executable, str(_SCRIPT_PATH),
                 '--table', 'agent_hallucinations',
                 '--match-value', 'test-agent'],
                capture_output=True,
                text=True,
                env=env
            )
            self.assertIn('agent_hallucinations', result.stdout)
        finally:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)

    def test_accepts_completeness_events_table(self):
        """completeness_events should be allowed."""
        tmpdir = tempfile.mkdtemp(prefix='honesty-test-')
        db_path = os.path.join(tmpdir, 'cast.db')
        conn = sqlite3.connect(db_path)
        conn.execute('CREATE TABLE completeness_events(agent TEXT, created_at TEXT)')
        conn.commit()
        conn.close()

        try:
            env = os.environ.copy()
            env['CAST_DB_PATH'] = db_path
            result = subprocess.run(
                [sys.executable, str(_SCRIPT_PATH),
                 '--table', 'completeness_events',
                 '--match-value', 'test-agent'],
                capture_output=True,
                text=True,
                env=env
            )
            self.assertIn('completeness_events', result.stdout)
        finally:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)


class TestCheckHonestTableDbAbsent(unittest.TestCase):
    """Test database absence handling."""

    def test_db_not_found_exits_2(self):
        """Missing DB file should exit 2 with 'skip' status."""
        env = os.environ.copy()
        env['CAST_DB_PATH'] = '/nonexistent/path/to/cast.db'
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_protocol_violations',
             '--match-value', 'x'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 2)
        output = json.loads(result.stdout)
        self.assertEqual(output['status'], 'skip')


class TestCheckHonestTableBasic(unittest.TestCase):
    """Test basic query logic."""

    def setUp(self):
        """Create a temp DB with test data."""
        self.tmpdir = tempfile.mkdtemp(prefix='honesty-test-')
        self.db_path = os.path.join(self.tmpdir, 'cast.db')
        self.conn = sqlite3.connect(self.db_path)

    def tearDown(self):
        """Clean up."""
        self.conn.close()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_no_matching_rows_exits_0_pass(self):
        """No matching rows should exit 0 with status='pass'."""
        self.conn.execute('CREATE TABLE agent_protocol_violations(agent_id TEXT, timestamp TEXT)')
        self.conn.commit()

        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_protocol_violations',
             '--match-value', 'missing-agent'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 0)
        output = json.loads(result.stdout)
        self.assertEqual(output['status'], 'pass')

    def test_matching_rows_exits_1_fail(self):
        """Matching rows should exit 1 with status='fail' and count."""
        self.conn.execute('CREATE TABLE agent_protocol_violations(agent_id TEXT, timestamp TEXT)')
        self.conn.execute("INSERT INTO agent_protocol_violations VALUES ('agent-x', '2026-01-01T00:00:00Z')")
        self.conn.execute("INSERT INTO agent_protocol_violations VALUES ('agent-x', '2026-01-02T00:00:00Z')")
        self.conn.commit()

        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_protocol_violations',
             '--match-value', 'agent-x'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 1)
        output = json.loads(result.stdout)
        self.assertEqual(output['status'], 'fail')
        self.assertEqual(output['count'], 2)


class TestCheckHonestTableVerified(unittest.TestCase):
    """Test verified column logic for agent_hallucinations."""

    def setUp(self):
        """Create a temp DB with agent_hallucinations table."""
        self.tmpdir = tempfile.mkdtemp(prefix='honesty-test-')
        self.db_path = os.path.join(self.tmpdir, 'cast.db')
        self.conn = sqlite3.connect(self.db_path)
        self.conn.execute(
            'CREATE TABLE agent_hallucinations'
            '(agent_name TEXT, timestamp TEXT, verified INTEGER)'
        )
        self.conn.commit()

    def tearDown(self):
        """Clean up."""
        self.conn.close()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_verified_true_not_counted(self):
        """Rows with verified=1 should NOT count as violations."""
        self.conn.execute(
            "INSERT INTO agent_hallucinations VALUES ('agent-a', '2026-01-01T00:00:00Z', 1)"
        )
        self.conn.commit()

        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_hallucinations',
             '--match-value', 'agent-a'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 0)
        output = json.loads(result.stdout)
        self.assertEqual(output['status'], 'pass')

    def test_verified_false_counted(self):
        """Rows with verified=0 should count as violations."""
        self.conn.execute(
            "INSERT INTO agent_hallucinations VALUES ('agent-b', '2026-01-01T00:00:00Z', 0)"
        )
        self.conn.commit()

        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_hallucinations',
             '--match-value', 'agent-b'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 1)
        output = json.loads(result.stdout)
        self.assertEqual(output['status'], 'fail')
        self.assertEqual(output['count'], 1)

    def test_verified_null_counted(self):
        """Rows with verified=NULL should count as violations."""
        self.conn.execute(
            "INSERT INTO agent_hallucinations VALUES ('agent-c', '2026-01-01T00:00:00Z', NULL)"
        )
        self.conn.commit()

        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_hallucinations',
             '--match-value', 'agent-c'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 1)
        output = json.loads(result.stdout)
        self.assertEqual(output['count'], 1)

    def test_mixed_verified_only_falsey_counted(self):
        """Only falsey verified rows should count."""
        self.conn.executescript("""
            INSERT INTO agent_hallucinations VALUES ('agent-d', '2026-01-01T00:00:00Z', 1);
            INSERT INTO agent_hallucinations VALUES ('agent-d', '2026-01-02T00:00:00Z', 0);
            INSERT INTO agent_hallucinations VALUES ('agent-d', '2026-01-03T00:00:00Z', 1);
            INSERT INTO agent_hallucinations VALUES ('agent-d', '2026-01-04T00:00:00Z', NULL);
        """)
        self.conn.commit()

        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_hallucinations',
             '--match-value', 'agent-d'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 1)
        output = json.loads(result.stdout)
        # Only 2 falsey rows should count (the 0 and the NULL)
        self.assertEqual(output['count'], 2)


class TestCheckHonestTableSince(unittest.TestCase):
    """Test --since timestamp filtering."""

    def setUp(self):
        """Create a temp DB with timestamped data."""
        self.tmpdir = tempfile.mkdtemp(prefix='honesty-test-')
        self.db_path = os.path.join(self.tmpdir, 'cast.db')
        self.conn = sqlite3.connect(self.db_path)
        self.conn.execute('CREATE TABLE agent_protocol_violations(agent_id TEXT, timestamp TEXT)')
        self.conn.executescript("""
            INSERT INTO agent_protocol_violations VALUES ('agent-x', '2026-01-01T00:00:00Z');
            INSERT INTO agent_protocol_violations VALUES ('agent-x', '2026-01-05T00:00:00Z');
            INSERT INTO agent_protocol_violations VALUES ('agent-x', '2026-01-10T00:00:00Z');
        """)
        self.conn.commit()

    def tearDown(self):
        """Clean up."""
        self.conn.close()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_since_filters_older_rows(self):
        """--since should exclude rows older than the timestamp."""
        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_protocol_violations',
             '--match-value', 'agent-x',
             '--since', '2026-01-06T00:00:00Z'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 1)
        output = json.loads(result.stdout)
        # Only the 2026-01-10 row should match (the 2026-01-05 is too old)
        self.assertEqual(output['count'], 1)

    def test_since_exact_match_included(self):
        """--since should include rows with timestamp equal to the filter."""
        env = os.environ.copy()
        env['CAST_DB_PATH'] = self.db_path
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH),
             '--table', 'agent_protocol_violations',
             '--match-value', 'agent-x',
             '--since', '2026-01-05T00:00:00Z'],
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 1)
        output = json.loads(result.stdout)
        # 2026-01-05 and 2026-01-10 should both match
        self.assertEqual(output['count'], 2)


class TestCheckHonestTableTableAbsent(unittest.TestCase):
    """Test handling of missing tables."""

    def test_table_not_in_db_exits_2(self):
        """Non-existent table should exit 2 with status='skip'."""
        tmpdir = tempfile.mkdtemp(prefix='honesty-test-')
        db_path = os.path.join(tmpdir, 'cast.db')
        conn = sqlite3.connect(db_path)
        conn.execute('CREATE TABLE dummy(x TEXT)')
        conn.commit()
        conn.close()

        try:
            env = os.environ.copy()
            env['CAST_DB_PATH'] = db_path
            result = subprocess.run(
                [sys.executable, str(_SCRIPT_PATH),
                 '--table', 'agent_protocol_violations',
                 '--match-value', 'x'],
                capture_output=True,
                text=True,
                env=env
            )
            self.assertEqual(result.returncode, 2)
            output = json.loads(result.stdout)
            self.assertEqual(output['status'], 'skip')
        finally:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
