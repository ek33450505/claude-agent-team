#!/usr/bin/env python3
"""Regression coverage for audit item P-1 (index-defeating date predicates).

`agent_runs.started_at` is indexed (idx_agent_runs_started_at,
scripts/cast-db-init.sh) but several call sites used to wrap the column in a
function — `DATE(started_at)=?` (bin/cast _cmd_status),
`date(replace(replace(started_at,'T',' '),'Z',''))=?` (bin/cast _cmd_budget),
and `started_at LIKE ? || '%'` (scripts/cast_subagent_stop.py
stage14_budget_alert) — all of which defeat the index (confirmed SCAN
agent_runs). The fix rewrites each as a half-open range on the RAW column
(`started_at >= ? [AND started_at < ?]`), which SQLite can satisfy via a
SEARCH on idx_agent_runs_started_at. agent_runs.started_at is uniformly
ISO-8601 'T'/'Z' form (verified 2026-09-15: 4650/4650 rows, no NULLs), so a
lexical range against plain YYYY-MM-DD bounds is correct — this does NOT
apply to columns with mixed timestamp formats elsewhere in cast.db.

Queries in TestExplainQueryPlanUsesIndex are extracted from the LIVE source
files by regex, not hardcoded copies — reverting a fixed call site back to
its function-wrapped form makes the corresponding test fail (mutation-tested
manually; see the P-1 fix session notes).
"""
import glob
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

_REPO_ROOT = Path(__file__).parent.parent
_BIN_CAST = _REPO_ROOT / "bin" / "cast"
_SUBAGENT_STOP_PATH = _REPO_ROOT / "scripts" / "cast_subagent_stop.py"
_DB_INIT_SH = _REPO_ROOT / "scripts" / "cast-db-init.sh"

_SCRIPTS_DIR = str(_REPO_ROOT / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_subagent_stop as css  # noqa: E402


def _build_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    os.remove(path)
    subprocess.run(
        ["bash", str(_DB_INIT_SH), "--db", path],
        check=True, capture_output=True, text=True,
    )
    return path


def _insert_run(conn, started_at, cost_usd):
    conn.execute(
        "INSERT INTO agent_runs (agent, started_at, cost_usd, status) "
        "VALUES (?, ?, ?, 'DONE')",
        ("test-agent", started_at, cost_usd),
    )
    conn.commit()


def _extract_all(pattern: str, text: str, label: str):
    matches = re.findall(pattern, text)
    if not matches:
        raise AssertionError(
            f"could not locate {label} in source — has the query been "
            "renamed/moved? Update this test's regex to match."
        )
    return matches


class TestExplainQueryPlanUsesIndex(unittest.TestCase):
    """Rewritten queries must SEARCH idx_agent_runs_started_at, never SCAN."""

    def setUp(self):
        self.db_path = _build_db()

    def tearDown(self):
        os.remove(self.db_path)

    def _assert_uses_index(self, sql, params):
        conn = sqlite3.connect(self.db_path)
        try:
            plan_rows = conn.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()
        finally:
            conn.close()
        plan_text = " | ".join(str(r) for r in plan_rows)
        self.assertNotIn(
            "SCAN agent_runs", plan_text,
            f"query defeats the index (full SCAN): {plan_text}\nSQL: {sql}",
        )
        self.assertIn(
            "idx_agent_runs_started_at", plan_text,
            f"query does not report using idx_agent_runs_started_at: {plan_text}\nSQL: {sql}",
        )

    def test_bin_cast_today_range_queries_use_index(self):
        """_cmd_status + _cmd_budget: WHERE started_at >= ? AND started_at < ?"""
        text = _BIN_CAST.read_text()
        matches = _extract_all(
            r'"(SELECT COALESCE\(SUM\(cost_usd\),0\) FROM agent_runs '
            r'WHERE started_at >= \? AND started_at < \?)"',
            text, "today half-open range query",
        )
        # Both _cmd_status and _cmd_budget carry this exact shape.
        self.assertGreaterEqual(len(matches), 2, "expected both _cmd_status and _cmd_budget to use this shape")
        for sql in matches:
            self._assert_uses_index(sql, ("2026-01-01", "2026-01-02"))

    def test_bin_cast_week_range_queries_use_index(self):
        """_cmd_status + _cmd_budget: WHERE started_at >= ? (no upper bound)."""
        text = _BIN_CAST.read_text()
        matches = _extract_all(
            r'"(SELECT COALESCE\(SUM\(cost_usd\),0\) FROM agent_runs WHERE started_at >= \?)"',
            text, "week open-ended range query",
        )
        self.assertGreaterEqual(len(matches), 2, "expected both _cmd_status and _cmd_budget to use this shape")
        for sql in matches:
            self._assert_uses_index(sql, ("2026-01-01",))

    def test_bin_cast_budget_week_breakdown_where_uses_index(self):
        """_cmd_budget week breakdown: GROUP BY day, but the WHERE predicate
        must still be a bare-column range (SELECT list may still format the
        column for display — that's not a predicate and doesn't affect
        index usage)."""
        text = _BIN_CAST.read_text()
        matches = _extract_all(
            r"(SELECT date\(replace\(replace\(started_at,'T',' '\),'Z',''\)\) as day, "
            r"COALESCE\(SUM\(cost_usd\),0\) as spend\s*\n\s*"
            r"FROM agent_runs WHERE started_at >= \? GROUP BY day ORDER BY day DESC)",
            text, "_cmd_budget week breakdown query",
        )
        self._assert_uses_index(matches[0], ("2026-01-01",))

    def test_cast_subagent_stop_budget_alert_query_uses_index(self):
        """stage14_budget_alert: WHERE started_at >= ? AND started_at < ?"""
        text = _SUBAGENT_STOP_PATH.read_text()
        matches = _extract_all(
            r'"(SELECT COALESCE\(SUM\(cost_usd\), 0\.0\) FROM agent_runs '
            r'WHERE started_at >= \? AND started_at < \?)"',
            text, "stage14_budget_alert today query",
        )
        self._assert_uses_index(matches[0], ("2026-01-01", "2026-01-02"))


class _IsolatedHomeTestCase(unittest.TestCase):
    """Redirects HOME to an isolated temp dir — stage14_budget_alert writes an
    alert-marker flag under ~/.claude/cast, which must never touch the real home."""

    def setUp(self):
        self._orig_home = os.environ.get("HOME")
        self._tmpdir = tempfile.mkdtemp(prefix="cast-p1-test-")
        os.environ["HOME"] = self._tmpdir

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self._orig_home
        shutil.rmtree(self._tmpdir, ignore_errors=True)


class TestBoundaryDateFixtureAndParity(_IsolatedHomeTestCase):
    """Boundary-date fixture: rows at 00:00:00Z, 23:59:59Z (both "today", must
    be included) and tomorrow's 00:00:00Z (must be EXCLUDED from "today").
    Covers Site 1 (_cmd_status), Site 2 (_cmd_budget) via the shared SQL
    shape, and Site 3 (stage14_budget_alert) via a direct function call.
    """

    def setUp(self):
        super().setUp()
        self.db_path = _build_db()
        now = datetime.now(timezone.utc)
        self.today = now.date()
        self.today_str = self.today.isoformat()
        self.tomorrow_str = (self.today + timedelta(days=1)).isoformat()
        conn = sqlite3.connect(self.db_path)
        try:
            _insert_run(conn, f"{self.today_str}T00:00:00Z", 1.00)
            _insert_run(conn, f"{self.today_str}T23:59:59Z", 2.00)
            _insert_run(conn, f"{self.tomorrow_str}T00:00:00Z", 100.00)  # must be excluded
        finally:
            conn.close()

    def tearDown(self):
        os.remove(self.db_path)
        super().tearDown()

    def test_half_open_range_excludes_tomorrow_row(self):
        conn = sqlite3.connect(self.db_path)
        try:
            today_next = (self.today + timedelta(days=1)).isoformat()
            row = conn.execute(
                "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs "
                "WHERE started_at >= ? AND started_at < ?",
                (self.today_str, today_next),
            ).fetchone()
        finally:
            conn.close()
        # 1.00 + 2.00, NOT + 100.00 from tomorrow.
        self.assertAlmostEqual(row[0], 3.00, places=4)

    def test_open_ended_week_range_includes_all_three(self):
        conn = sqlite3.connect(self.db_path)
        try:
            week_ago = (self.today - timedelta(days=7)).isoformat()
            row = conn.execute(
                "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs WHERE started_at >= ?",
                (week_ago,),
            ).fetchone()
        finally:
            conn.close()
        # No upper bound: today's two rows AND tomorrow's row are all >= week_ago.
        self.assertAlmostEqual(row[0], 103.00, places=4)

    def test_stage14_budget_alert_reports_today_sum_excluding_tomorrow(self):
        """Result-parity for Site 3: the alert message must embed the SAME
        today-sum (3.00, excluding the $100 tomorrow row) that the half-open
        range query computes directly."""
        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                "INSERT INTO budgets (scope, period, limit_usd, alert_at_pct) "
                "VALUES ('global', 'daily', ?, ?)",
                (3.75, 0.70),
            )
            conn.commit()
        finally:
            conn.close()

        ctx = css.Ctx()
        ctx.db_present = True
        ctx.db_path = self.db_path
        ctx.session_id = "test-session"

        buf = io.StringIO()
        with redirect_stdout(buf):
            css.stage14_budget_alert(ctx)
        printed = buf.getvalue().strip()
        self.assertTrue(printed, "stage14_budget_alert emitted no output — expected a budget alert")
        payload = json.loads(printed)
        msg = payload["hookSpecificOutput"]["additionalContext"]
        # today_spend must be 3.0000 (1.00 + 2.00), never 103.0000 (would mean
        # the tomorrow row leaked in) and never 0.0000 (would mean the range
        # excluded today's own rows too).
        self.assertIn("$3.0000", msg, f"unexpected today_spend in alert message: {msg!r}")
        self.assertNotIn("$103.0000", msg, f"tomorrow's row leaked into today_spend: {msg!r}")

        # Clean up the alert-marker flag this run wrote under the isolated HOME
        # so a re-run within the same test session isn't deduped by O_EXCL.
        for flag in glob.glob(os.path.join(self._tmpdir, ".claude", "cast", "budget-alert-*.flag")):
            os.remove(flag)


if __name__ == "__main__":
    unittest.main()
