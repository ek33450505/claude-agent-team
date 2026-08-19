#!/usr/bin/env python3
"""Unit tests for scripts/cast-db-rollup.py — the pre-prune rollup writer (C5).

Pattern: each test builds its own temp SQLite DB (tempfile, never the real
~/.claude/cast.db) and invokes the script under test as a subprocess with
CAST_DB_PATH pointed at that temp DB (mirrors tests/test_cast_db_sql_injection.py's
house style of exercising a script end-to-end rather than importing it).

Dates are computed RELATIVE to real wall-clock time (never hardcoded literals)
so these tests stay correct regardless of when they run. Tests that care about
the authoritative/insert-only window boundary pass `--authoritative-days`
explicitly for a deterministic cutoff, rather than relying on the default
(CAST_DB_PRUNE_DAYS, else 90) and real elapsed time.

Covers:
  1. exact aggregates across 3 days x 2 agents x 2 models x 2 statuses
  2. idempotency (run twice -> identical rows/values)
  3. the monotone non-shrinking guard on the INSERT-ONLY (old-day) side
  4. NULL agent/model/status collapse to '' with no duplicate rows on rerun
  5. an already-pruned OLD day (aggregate present, zero raw rows) is preserved
  6. mcp_calls_daily aggregation + malformed-JSON rows are skipped, not fatal
  7. a missing rollup table fails closed (exit 1, remediation named)
  8. --dry-run writes nothing and exits 0
  9. status-mutation regression (running -> abandoned) on the AUTHORITATIVE
     (recent-day) side collapses to exactly one corrected row
 10. the authoritative-window BOUNDARY (day == cutoff_day) is insert-only
 11. excluded-row counts appear in the JSON summary and are non-zero when fed
     an excluded-shaped row of each kind
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_SCRIPT_PATH = Path(__file__).parent.parent / 'scripts' / 'cast-db-rollup.py'

# Raw table schemas copied from scripts/cast-db-init.sh (agent_runs, routing_events)
# and the two daily rollup tables (agent_runs_daily, mcp_calls_daily) added for C5.
_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS agent_runs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  agent           TEXT,
  model           TEXT,
  started_at      TEXT,
  ended_at        TEXT,
  status          TEXT,
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  cost_usd        REAL,
  agent_id        TEXT,
  response        TEXT,
  cache_read_input_tokens INTEGER,
  cache_creation_input_tokens INTEGER,
  duration_ms     INTEGER,
  tool_uses       INTEGER,
  files           TEXT,
  file_class      TEXT,
  abandoned_at    TIMESTAMP,
  branch          TEXT
);

CREATE TABLE IF NOT EXISTS routing_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  timestamp       TEXT,
  prompt_preview  TEXT,
  action          TEXT,
  matched_route   TEXT,
  pattern         TEXT,
  confidence      TEXT,
  project         TEXT,
  event_type      TEXT,
  data            TEXT
);

CREATE TABLE IF NOT EXISTS agent_runs_daily (
  day            TEXT NOT NULL,
  agent          TEXT NOT NULL DEFAULT '',
  model          TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT '',
  runs           INTEGER NOT NULL DEFAULT 0,
  with_response  INTEGER NOT NULL DEFAULT 0,
  input_tokens   INTEGER NOT NULL DEFAULT 0,
  output_tokens  INTEGER NOT NULL DEFAULT 0,
  cache_read_input_tokens     INTEGER NOT NULL DEFAULT 0,
  cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd       REAL    NOT NULL DEFAULT 0,
  duration_ms    INTEGER NOT NULL DEFAULT 0,
  tool_uses      INTEGER NOT NULL DEFAULT 0,
  rolled_up_at   TEXT    NOT NULL,
  PRIMARY KEY (day, agent, model, status)
);
CREATE INDEX IF NOT EXISTS idx_agent_runs_daily_day ON agent_runs_daily(day);

CREATE TABLE IF NOT EXISTS mcp_calls_daily (
  day            TEXT NOT NULL,
  mcp_server     TEXT NOT NULL DEFAULT '',
  mcp_tool       TEXT NOT NULL DEFAULT '',
  outcome        TEXT NOT NULL DEFAULT '',
  is_cloud_bound INTEGER NOT NULL DEFAULT 0,
  calls          INTEGER NOT NULL DEFAULT 0,
  result_bytes   INTEGER NOT NULL DEFAULT 0,
  rolled_up_at   TEXT    NOT NULL,
  PRIMARY KEY (day, mcp_server, mcp_tool, outcome, is_cloud_bound)
);
CREATE INDEX IF NOT EXISTS idx_mcp_calls_daily_day ON mcp_calls_daily(day);
"""

# Schema without the two daily rollup tables — used by the missing-table test (7).
_SCHEMA_SQL_NO_DAILY_TABLES = """
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT, model TEXT, started_at TEXT, status TEXT
);
CREATE TABLE IF NOT EXISTS routing_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT, event_type TEXT, data TEXT
);
"""

# Standard test window: small so "old" days (well past the window) and
# "recent" days (well inside it) can both be reached with small day-offsets.
_TEST_AUTH_DAYS = 5


def _days_ago(n: int) -> str:
    """UTC calendar day string n days before now — mirrors cast-db-rollup.py's
    own _cutoff_day() computation so tests reason in the same units."""
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime('%Y-%m-%d')


class RollupTestBase(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.mkdtemp(prefix='cast-rollup-test-')
        self.db_path = os.path.join(self._tmpdir, 'test-cast.db')

    def tearDown(self):
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _init_schema(self, sql: str = _SCHEMA_SQL) -> None:
        conn = sqlite3.connect(self.db_path)
        try:
            conn.executescript(sql)
            conn.commit()
        finally:
            conn.close()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _run_rollup(self, extra_args=None) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env['CAST_DB_PATH'] = self.db_path
        env.pop('CAST_DB_ROLLUP_DRY_RUN', None)
        # Never let an ambient CAST_DB_PRUNE_DAYS leak into a test's window —
        # every window-sensitive test passes --authoritative-days explicitly.
        env.pop('CAST_DB_PRUNE_DAYS', None)
        cmd = [sys.executable, str(_SCRIPT_PATH)] + list(extra_args or [])
        return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)

    def _insert_agent_run(self, agent, model, started_at, status,
                           input_tokens=0, output_tokens=0, cost_usd=0.0,
                           duration_ms=0, tool_uses=0, response='ok',
                           cache_read=0, cache_creation=0):
        conn = self._connect()
        try:
            conn.execute(
                """INSERT INTO agent_runs
                   (agent, model, started_at, status, input_tokens, output_tokens,
                    cost_usd, duration_ms, tool_uses, response,
                    cache_read_input_tokens, cache_creation_input_tokens)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (agent, model, started_at, status, input_tokens, output_tokens,
                 cost_usd, duration_ms, tool_uses, response, cache_read, cache_creation),
            )
            conn.commit()
        finally:
            conn.close()

    def _insert_routing_event(self, timestamp, event_type, data):
        conn = self._connect()
        try:
            conn.execute(
                "INSERT INTO routing_events (timestamp, event_type, data) VALUES (?, ?, ?)",
                (timestamp, event_type, data),
            )
            conn.commit()
        finally:
            conn.close()


class TestExactAggregates(RollupTestBase):
    """(1) 3 recent days x 2 agents x 2 models x 2 statuses -> every summed
    column exact. Recent days fall on the AUTHORITATIVE side of a 90-day
    window, but a single rollup call (no mutation between runs) behaves
    identically on either side."""

    def test_exact_aggregates(self):
        self._init_schema()
        days = [_days_ago(3), _days_ago(4), _days_ago(5)]
        agents = ['backend-writer', 'code-reviewer']
        models = ['sonnet', 'haiku']
        statuses = ['DONE', 'DONE_WITH_CONCERNS']
        for day in days:
            for agent in agents:
                for model in models:
                    for status in statuses:
                        self._insert_agent_run(
                            agent, model, f'{day}T09:00:00Z', status,
                            input_tokens=100, output_tokens=200, cost_usd=0.5,
                            duration_ms=1000, tool_uses=3, response='ok',
                            cache_read=10, cache_creation=5,
                        )
                        self._insert_agent_run(
                            agent, model, f'{day}T10:00:00Z', status,
                            input_tokens=50, output_tokens=25, cost_usd=0.25,
                            duration_ms=500, tool_uses=2, response='',
                            cache_read=1, cache_creation=1,
                        )

        result = self._run_rollup(['--authoritative-days', '90'])
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(summary['agent_runs_daily'], 3 * 2 * 2 * 2)

        conn = self._connect()
        try:
            rows = conn.execute(
                'SELECT * FROM agent_runs_daily WHERE day=? AND agent=? AND model=? AND status=?',
                (days[0], 'backend-writer', 'sonnet', 'DONE'),
            ).fetchall()
        finally:
            conn.close()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row['runs'], 2)
        self.assertEqual(row['with_response'], 1)
        self.assertEqual(row['input_tokens'], 150)
        self.assertEqual(row['output_tokens'], 225)
        self.assertEqual(row['cache_read_input_tokens'], 11)
        self.assertEqual(row['cache_creation_input_tokens'], 6)
        self.assertAlmostEqual(row['cost_usd'], 0.75)
        self.assertEqual(row['duration_ms'], 1500)
        self.assertEqual(row['tool_uses'], 5)
        self.assertTrue(row['rolled_up_at'])


class TestIdempotency(RollupTestBase):
    """(2) Running twice produces identical row count AND identical values
    on the AUTHORITATIVE (recent-day) side, where each run does a full
    delete+rebuild of that day."""

    def test_idempotent_rerun(self):
        self._init_schema()
        day = _days_ago(1)
        self._insert_agent_run('backend-writer', 'sonnet', f'{day}T09:00:00Z', 'DONE',
                                input_tokens=100, output_tokens=200, cost_usd=1.0)
        self._insert_agent_run('backend-writer', 'sonnet', f'{day}T10:00:00Z', 'DONE',
                                input_tokens=50, output_tokens=75, cost_usd=0.5)

        r1 = self._run_rollup(['--authoritative-days', '90'])
        self.assertEqual(r1.returncode, 0, r1.stderr)
        conn = self._connect()
        try:
            row1 = dict(conn.execute('SELECT * FROM agent_runs_daily').fetchone())
            count1 = conn.execute('SELECT COUNT(*) FROM agent_runs_daily').fetchone()[0]
        finally:
            conn.close()

        r2 = self._run_rollup(['--authoritative-days', '90'])
        self.assertEqual(r2.returncode, 0, r2.stderr)
        conn = self._connect()
        try:
            row2 = dict(conn.execute('SELECT * FROM agent_runs_daily').fetchone())
            count2 = conn.execute('SELECT COUNT(*) FROM agent_runs_daily').fetchone()[0]
        finally:
            conn.close()

        self.assertEqual(count1, count2)
        for key in ('runs', 'with_response', 'input_tokens', 'output_tokens', 'cost_usd'):
            self.assertEqual(row1[key], row2[key], f'{key} mismatch across reruns')


class TestMonotoneGuard(RollupTestBase):
    """(3) Re-anchored to a day OLDER than the authoritative window (so it
    actually exercises the INSERT-ONLY path): a partial delete of raw rows
    must never shrink a stored rollup — this is what
    `WHERE excluded.runs >= agent_runs_daily.runs` exists to prevent."""

    def test_partial_delete_does_not_shrink_rollup(self):
        self._init_schema()
        old_day = _days_ago(30)  # well past a 5-day authoritative window
        for i in range(10):
            self._insert_agent_run(
                'backend-writer', 'sonnet', f'{old_day}T{9 + i % 10:02d}:00:00Z', 'DONE',
                input_tokens=10, output_tokens=10, cost_usd=0.1,
            )

        r1 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r1.returncode, 0, r1.stderr)
        conn = self._connect()
        try:
            runs_before = conn.execute(
                'SELECT runs FROM agent_runs_daily WHERE day=?', (old_day,)
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(runs_before, 10)

        # Simulate a mid-day prune cutoff: delete 6 of the 10 raw rows.
        conn = self._connect()
        try:
            ids = [r[0] for r in conn.execute('SELECT id FROM agent_runs ORDER BY id').fetchall()]
            for row_id in ids[:6]:
                conn.execute('DELETE FROM agent_runs WHERE id=?', (row_id,))
            conn.commit()
        finally:
            conn.close()

        r2 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r2.returncode, 0, r2.stderr)
        conn = self._connect()
        try:
            runs_after = conn.execute(
                'SELECT runs FROM agent_runs_daily WHERE day=?', (old_day,)
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(
            runs_after, 10,
            'monotone guard failed: rollup shrank from 10 to '
            f'{runs_after} after a partial raw-row delete — the '
            "'WHERE excluded.runs >= agent_runs_daily.runs' guard did not hold",
        )


class TestNullCollapse(RollupTestBase):
    """(4) NULL agent/model/status collapse to '' and do not duplicate on rerun."""

    def test_null_fields_collapse_and_no_duplicates(self):
        self._init_schema()
        day = _days_ago(1)
        self._insert_agent_run(None, None, f'{day}T09:00:00Z', None, input_tokens=5)
        self._insert_agent_run(None, None, f'{day}T10:00:00Z', None, input_tokens=7)

        r1 = self._run_rollup(['--authoritative-days', '90'])
        self.assertEqual(r1.returncode, 0, r1.stderr)
        conn = self._connect()
        try:
            rows = conn.execute('SELECT * FROM agent_runs_daily WHERE day=?', (day,)).fetchall()
        finally:
            conn.close()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['agent'], '')
        self.assertEqual(rows[0]['model'], '')
        self.assertEqual(rows[0]['status'], '')
        self.assertEqual(rows[0]['runs'], 2)
        self.assertEqual(rows[0]['input_tokens'], 12)

        r2 = self._run_rollup(['--authoritative-days', '90'])
        self.assertEqual(r2.returncode, 0, r2.stderr)
        conn = self._connect()
        try:
            count = conn.execute('SELECT COUNT(*) FROM agent_runs_daily WHERE day=?', (day,)).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(count, 1, 'NULL-key collapse produced a duplicate row on rerun')


class TestAlreadyPrunedDayPreserved(RollupTestBase):
    """(5) Re-anchored to a day OLDER than the authoritative window: a day
    whose raw rows are already gone (aggregate exists, 0 raw rows) must never
    be deleted or zeroed by a subsequent rollup run — the insert-only side
    never issues a DELETE."""

    def test_pruned_day_preserved(self):
        self._init_schema()
        old_day = _days_ago(30)
        self._insert_agent_run('backend-writer', 'sonnet', f'{old_day}T09:00:00Z', 'DONE',
                                input_tokens=42, output_tokens=84, cost_usd=2.0)
        r1 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r1.returncode, 0, r1.stderr)

        # Simulate cast-db-prune.py deleting the now-rolled-up raw row entirely.
        conn = self._connect()
        try:
            conn.execute("DELETE FROM agent_runs WHERE started_at=?", (f'{old_day}T09:00:00Z',))
            conn.commit()
        finally:
            conn.close()

        r2 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r2.returncode, 0, r2.stderr)
        conn = self._connect()
        try:
            row = conn.execute('SELECT * FROM agent_runs_daily WHERE day=?', (old_day,)).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row, 'already-pruned day was deleted by a subsequent rollup')
        self.assertEqual(row['runs'], 1)
        self.assertEqual(row['input_tokens'], 42)


class TestMcpCallsAggregation(RollupTestBase):
    """(6) mcp_calls_daily aggregates real-shaped payloads; invalid JSON is
    skipped without crashing and without aborting the valid rows."""

    def test_mcp_calls_aggregate_and_skip_invalid_json(self):
        self._init_schema()
        day = _days_ago(1)
        valid_payload_1 = json.dumps({
            'timestamp': f'{day}T20:57:33Z', 'session_id': 'sess-1',
            'project': 'claude-agent-team', 'tool_name': 'mcp__cloudflare__docs',
            'is_cloud_bound': True, 'mcp_server': 'cloudflare', 'mcp_tool': 'docs',
            'args_summary': 'query:str(27)', 'outcome': 'ok', 'result_size': 20119,
            'input_hash': '21e7a5a3c48a73c3',
        })
        valid_payload_2 = json.dumps({
            'timestamp': f'{day}T21:10:00Z', 'session_id': 'sess-2',
            'project': 'claude-agent-team', 'tool_name': 'mcp__cloudflare__docs',
            'is_cloud_bound': True, 'mcp_server': 'cloudflare', 'mcp_tool': 'docs',
            'outcome': 'ok', 'result_size': 881,
        })
        local_payload = json.dumps({
            'timestamp': f'{day}T21:15:00Z', 'mcp_server': 'sqlite',
            'mcp_tool': 'query', 'is_cloud_bound': False, 'outcome': 'error',
            'result_size': 0,
        })

        self._insert_routing_event(f'{day}T20:57:33Z', 'mcp_tool_call', valid_payload_1)
        self._insert_routing_event(f'{day}T21:10:00Z', 'mcp_tool_call', valid_payload_2)
        self._insert_routing_event(f'{day}T21:15:00Z', 'mcp_tool_call', local_payload)
        # Malformed JSON — must be skipped, not fatal.
        self._insert_routing_event(f'{day}T21:20:00Z', 'mcp_tool_call', '{not valid json')
        # A non-mcp_tool_call event must never be picked up by the aggregation.
        self._insert_routing_event(f'{day}T21:25:00Z', 'other_event', valid_payload_1)

        result = self._run_rollup(['--authoritative-days', '90'])
        self.assertEqual(result.returncode, 0, result.stderr)

        conn = self._connect()
        try:
            cloudflare_row = conn.execute(
                "SELECT * FROM mcp_calls_daily WHERE mcp_server='cloudflare' AND mcp_tool='docs'"
            ).fetchone()
            sqlite_row = conn.execute(
                "SELECT * FROM mcp_calls_daily WHERE mcp_server='sqlite'"
            ).fetchone()
            total_rows = conn.execute('SELECT COUNT(*) FROM mcp_calls_daily').fetchone()[0]
        finally:
            conn.close()

        self.assertIsNotNone(cloudflare_row)
        self.assertEqual(cloudflare_row['calls'], 2)
        self.assertEqual(cloudflare_row['result_bytes'], 20119 + 881)
        self.assertEqual(cloudflare_row['is_cloud_bound'], 1)
        self.assertEqual(cloudflare_row['outcome'], 'ok')

        self.assertIsNotNone(sqlite_row)
        self.assertEqual(sqlite_row['calls'], 1)
        self.assertEqual(sqlite_row['is_cloud_bound'], 0)
        self.assertEqual(sqlite_row['outcome'], 'error')

        self.assertEqual(total_rows, 2)


class TestMissingRollupTableFailsClosed(RollupTestBase):
    """(7) A missing rollup table exits 1 and names the migrate remediation."""

    def test_missing_table_exit_code_and_remediation(self):
        self._init_schema(_SCHEMA_SQL_NO_DAILY_TABLES)
        result = self._run_rollup()
        self.assertEqual(result.returncode, 1)
        self.assertIn('cast-migrate.py --confirm', result.stderr)
        self.assertIn('agent_runs_daily', result.stderr)


class TestDryRun(RollupTestBase):
    """(8) --dry-run writes nothing and exits 0."""

    def test_dry_run_writes_nothing(self):
        self._init_schema()
        day = _days_ago(1)
        self._insert_agent_run('backend-writer', 'sonnet', f'{day}T09:00:00Z', 'DONE',
                                input_tokens=100, output_tokens=200, cost_usd=1.0)
        self._insert_routing_event(
            f'{day}T09:05:00Z', 'mcp_tool_call',
            json.dumps({'timestamp': f'{day}T09:05:00Z', 'mcp_server': 'cloudflare',
                        'mcp_tool': 'docs', 'outcome': 'ok', 'is_cloud_bound': True,
                        'result_size': 100}),
        )

        conn = self._connect()
        try:
            before_runs = conn.execute('SELECT COUNT(*) FROM agent_runs_daily').fetchone()[0]
            before_mcp = conn.execute('SELECT COUNT(*) FROM mcp_calls_daily').fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(before_runs, 0)
        self.assertEqual(before_mcp, 0)

        result = self._run_rollup(['--dry-run'])
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertTrue(summary['dry_run'])
        self.assertEqual(summary['agent_runs_daily'], 1)
        self.assertEqual(summary['mcp_calls_daily'], 1)
        self.assertIn('excluded_agent_runs', summary)
        self.assertIn('excluded_mcp_calls', summary)
        self.assertEqual(summary['excluded_agent_runs'], 0)
        self.assertEqual(summary['excluded_mcp_calls'], 0)

        conn = self._connect()
        try:
            after_runs = conn.execute('SELECT COUNT(*) FROM agent_runs_daily').fetchone()[0]
            after_mcp = conn.execute('SELECT COUNT(*) FROM mcp_calls_daily').fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(after_runs, 0, '--dry-run must not write any rows')
        self.assertEqual(after_mcp, 0, '--dry-run must not write any rows')


class TestStatusMutationRegression(RollupTestBase):
    """(9) ⭐ THE load-bearing regression test for FIX 1. A run dated inside
    the authoritative window is rolled up as 'running', then the raw row is
    mutated (in place, matching cast-abandon-stale-runs.py's real behavior)
    to 'abandoned', then rolled up again. Must produce EXACTLY ONE row for
    that day, status 'abandoned', SUM(runs)=1 — the stale 'running' phantom
    must be gone, not merely un-shrunk."""

    def test_status_mutation_corrected_not_duplicated(self):
        self._init_schema()
        day = _days_ago(1)  # inside a 5-day authoritative window
        self._insert_agent_run('backend-writer', 'sonnet', f'{day}T09:00:00Z', 'running',
                                input_tokens=10, output_tokens=20, cost_usd=0.3)

        r1 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r1.returncode, 0, r1.stderr)
        conn = self._connect()
        try:
            rows = conn.execute('SELECT * FROM agent_runs_daily WHERE day=?', (day,)).fetchall()
        finally:
            conn.close()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['status'], 'running')
        self.assertEqual(rows[0]['runs'], 1)

        # In-place mutation — exactly what cast-abandon-stale-runs.py does.
        conn = self._connect()
        try:
            conn.execute("UPDATE agent_runs SET status='abandoned' WHERE started_at=?",
                         (f'{day}T09:00:00Z',))
            conn.commit()
        finally:
            conn.close()

        r2 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r2.returncode, 0, r2.stderr)
        conn = self._connect()
        try:
            rows = conn.execute('SELECT * FROM agent_runs_daily WHERE day=?', (day,)).fetchall()
            total_runs = conn.execute(
                'SELECT COALESCE(SUM(runs),0) FROM agent_runs_daily WHERE day=?', (day,)
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(
            len(rows), 1,
            f'expected exactly 1 row for {day} after the status flip, found {len(rows)}: '
            f'{[dict(r) for r in rows]} — a stale status group was not corrected',
        )
        self.assertEqual(rows[0]['status'], 'abandoned')
        self.assertEqual(rows[0]['runs'], 1)
        self.assertEqual(total_runs, 1, f'SUM(runs) for {day} should be 1 (one real run), got {total_runs}')


class TestAuthoritativeWindowBoundary(RollupTestBase):
    """(10) cutoff_day itself must be INSERT-ONLY, never authoritative. If
    the day-comparison were `>=` instead of `>`, cutoff_day would be treated
    as authoritative and a delete-then-rebuild against a day whose raw rows
    may already be PARTIALLY pruned (the prune cutoff is a mid-day instant)
    would shrink the aggregate — exactly the TestMonotoneGuard failure mode,
    reproduced at the boundary itself."""

    def test_cutoff_day_itself_is_insert_only_not_authoritative(self):
        self._init_schema()
        cutoff_day = _days_ago(_TEST_AUTH_DAYS)
        for i in range(10):
            self._insert_agent_run(
                'bnd', 'model', f'{cutoff_day}T{9 + i % 10:02d}:00:00Z', 'DONE',
                input_tokens=1,
            )

        r1 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r1.returncode, 0, r1.stderr)
        conn = self._connect()
        try:
            runs_before = conn.execute(
                'SELECT runs FROM agent_runs_daily WHERE day=?', (cutoff_day,)
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(runs_before, 10)

        # Partially delete raw rows for the boundary day (simulating a mid-day prune cutoff).
        conn = self._connect()
        try:
            ids = [r[0] for r in conn.execute("SELECT id FROM agent_runs WHERE agent='bnd' ORDER BY id").fetchall()]
            for row_id in ids[:6]:
                conn.execute('DELETE FROM agent_runs WHERE id=?', (row_id,))
            conn.commit()
        finally:
            conn.close()

        r2 = self._run_rollup(['--authoritative-days', str(_TEST_AUTH_DAYS)])
        self.assertEqual(r2.returncode, 0, r2.stderr)
        conn = self._connect()
        try:
            runs_after = conn.execute(
                'SELECT runs FROM agent_runs_daily WHERE day=?', (cutoff_day,)
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(
            runs_after, 10,
            'boundary day (day == cutoff_day) was treated as AUTHORITATIVE and shrank from 10 to '
            f'{runs_after} — the day>cutoff_day comparison must be strict (>), not (>=); day==cutoff_day '
            'must stay on the insert-only/monotone-guarded side since the prune cutoff is a mid-day '
            'instant and cutoff_day itself may already be partially deleted.',
        )


class TestExcludedCounts(RollupTestBase):
    """(11) Excluded-row counts (FIX 2 / security MEDIUM) appear in the JSON
    summary and are non-zero when fed one excluded row of each kind."""

    def test_excluded_counts_nonzero_and_reported(self):
        self._init_schema()
        day = _days_ago(1)
        # Included row, for contrast.
        self._insert_agent_run('backend-writer', 'sonnet', f'{day}T09:00:00Z', 'DONE', input_tokens=1)
        # Excluded: empty-string started_at (the genuinely losable shape per
        # the module docstring — a NULL started_at is immune to pruning, but
        # an empty string is deleted by prune while excluded from rollup).
        self._insert_agent_run('backend-writer', 'sonnet', '', 'DONE', input_tokens=1)
        self._insert_agent_run('backend-writer', 'sonnet', None, 'DONE', input_tokens=1)

        # Included mcp row, for contrast.
        self._insert_routing_event(
            f'{day}T10:00:00Z', 'mcp_tool_call',
            json.dumps({'timestamp': f'{day}T10:00:00Z', 'mcp_server': 'cloudflare',
                        'mcp_tool': 'docs', 'outcome': 'ok', 'is_cloud_bound': True,
                        'result_size': 10}),
        )
        # Excluded: invalid JSON.
        self._insert_routing_event(f'{day}T10:05:00Z', 'mcp_tool_call', 'not json at all')
        # Excluded: valid JSON but missing $.timestamp.
        self._insert_routing_event(
            f'{day}T10:10:00Z', 'mcp_tool_call',
            json.dumps({'mcp_server': 'cloudflare', 'mcp_tool': 'docs', 'outcome': 'ok'}),
        )

        result = self._run_rollup(['--authoritative-days', '90'])
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(
            summary['excluded_agent_runs'], 2,
            f'expected 2 excluded agent_runs rows (empty-string + NULL started_at), got summary={summary}',
        )
        self.assertEqual(
            summary['excluded_mcp_calls'], 2,
            f'expected 2 excluded mcp_tool_call rows (invalid JSON + missing timestamp), got summary={summary}',
        )


class TestCliFlags(RollupTestBase):
    """--help exits 0; an unknown flag exits 2 without touching the DB."""

    def test_help_exits_zero(self):
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH), '--help'],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0)

    def test_unknown_flag_exits_two(self):
        result = subprocess.run(
            [sys.executable, str(_SCRIPT_PATH), '--bogus-flag'],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
