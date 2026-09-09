#!/usr/bin/env python3
"""Tests for scripts/cast-workflow-model-audit.py opus detection.

REGRESSION THIS PINS
--------------------
The audit counted opus with `model = 'claude-opus-4-8'`. When the fleet moved
to claude-opus-5 the query matched nothing, so the script reported 0.0% opus
and exited 0 while 150 opus-5 workflow stages ($471.68) were running. Against
the live record on 2026-09-09 the blind version scored week 2026-35 at 6.5%;
the fixed version scores the same week at 71.2% -- above the 60% WARN
threshold. The gate was suppressing a real alarm.

test_opus5_runs_are_counted is the discriminating case: it FAILS against the
pre-fix equality test and PASSES against the substring match.

The script is run as a subprocess with CAST_DB_PATH pointed at a temp sqlite
file, so this exercises the real default path (no import-time monkeypatching)
and never touches the live ~/.claude/cast.db.
"""
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).parent.parent / 'scripts' / 'cast-workflow-model-audit.py'
_WEEK = '2026-09-01T10:00:00Z'  # all rows land in one ISO week


class WorkflowModelAuditOpusDetectionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='cast-audit-test-')
        self.db = os.path.join(self.tmp, 'cast.db')
        conn = sqlite3.connect(self.db)
        conn.execute(
            'CREATE TABLE agent_runs ('
            ' id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT, model TEXT,'
            ' started_at TEXT, cost_usd REAL)'
        )
        conn.commit()
        conn.close()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _seed(self, model, n):
        conn = sqlite3.connect(self.db)
        conn.executemany(
            'INSERT INTO agent_runs (agent, model, started_at, cost_usd)'
            ' VALUES (?,?,?,?)',
            [('workflow-subagent', model, _WEEK, 3.14) for _ in range(n)],
        )
        conn.commit()
        conn.close()

    def _run(self):
        env = dict(os.environ, CAST_DB_PATH=self.db)
        env.pop('CAST_DB_URL', None)
        p = subprocess.run(
            [sys.executable, str(_SCRIPT)], env=env,
            capture_output=True, text=True,
        )
        return p.returncode, p.stdout + p.stderr

    # --- the discriminating case: fails against the pre-fix equality test ---
    def test_opus5_runs_are_counted(self):
        self._seed('claude-opus-5', 10)
        rc, out = self._run()
        self.assertIn('100.0%', out, 'opus-5 runs must be counted as opus')
        self.assertEqual(rc, 1, 'an all-opus week must WARN')
        self.assertIn('WARN', out)

    def test_opus48_is_still_counted(self):
        """The original id must keep working -- this is a widening, not a swap."""
        self._seed('claude-opus-4-8', 10)
        rc, out = self._run()
        self.assertEqual(rc, 1)
        self.assertIn('100.0%', out)

    def test_mixed_opus_generations_are_summed(self):
        self._seed('claude-opus-5', 7)
        self._seed('claude-opus-4-8', 3)
        rc, out = self._run()
        self.assertEqual(rc, 1)
        self.assertIn('100.0%', out)

    # --- control: non-opus must NOT be counted (guards over-matching) ------
    def test_sonnet_and_haiku_are_not_counted_as_opus(self):
        self._seed('claude-sonnet-5', 8)
        self._seed('claude-haiku-4-5-20251001', 4)
        rc, out = self._run()
        self.assertEqual(rc, 0, 'a week with no opus must not WARN')
        self.assertIn('0.0%', out)
        self.assertIn('OK', out)

    def test_below_threshold_week_does_not_warn(self):
        self._seed('claude-opus-5', 2)
        self._seed('claude-sonnet-5', 8)
        rc, out = self._run()
        self.assertEqual(rc, 0, '20% opus is below the 60% warn threshold')
        self.assertIn('20.0%', out)


if __name__ == '__main__':
    unittest.main()
