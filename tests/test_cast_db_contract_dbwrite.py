#!/usr/bin/env python3
"""Tests for db_write() dynamic-writer detection in cast-db-contract.py.

Covers:
  (a) db_write('t', {'a':1,'b':2}) → columns a,b classify KEEP not SAFE-DROP
  (b) db_write('t', var) where t is in ALLOWED_TABLES → t's declared columns
      are KEEP (dynamic-writer), not SAFE-DROP
  (c) A table NOT in ALLOWED_TABLES with a reader and no writer still classifies
      FIX-WRITER — no false KEEP promotion

Loads cast-db-contract.py via importlib to avoid import-name issues (hyphens).
"""
import importlib.util
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
_CONTRACT_PATH = _SCRIPTS_DIR / "cast-db-contract.py"

_spec = importlib.util.spec_from_file_location("cast_db_contract", str(_CONTRACT_PATH))
_mod = importlib.util.module_from_spec(_spec)
sys.modules["cast_db_contract"] = _mod  # required for @dataclass to resolve the module
_spec.loader.exec_module(_mod)

extract_allowed_tables = _mod.extract_allowed_tables
scan_db_write_calls = _mod.scan_db_write_calls
build_contracts = _mod.build_contracts
ColumnContract = _mod.ColumnContract
_parse_sql_ops = _mod._parse_sql_ops
parse_auto_populated = _mod.parse_auto_populated
parse_contract_directives = _mod.parse_contract_directives
parse_init_schema = _mod.parse_init_schema


class TestExtractAllowedTables(unittest.TestCase):
    """extract_allowed_tables() parses ALLOWED_TABLES from cast_db.py."""

    def test_extracts_known_tables(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write(textwrap.dedent("""
                ALLOWED_TABLES = {
                    'agent_protocol_violations',
                    'agent_truncations',
                    'dispatch_decisions',
                }
            """))
            tmp = Path(f.name)
        try:
            tables = extract_allowed_tables(tmp)
            self.assertIn("agent_protocol_violations", tables)
            self.assertIn("agent_truncations", tables)
            self.assertIn("dispatch_decisions", tables)
        finally:
            tmp.unlink()

    def test_missing_file_returns_empty(self):
        tables = extract_allowed_tables(Path("/nonexistent/cast_db.py"))
        self.assertEqual(tables, set())

    def test_reads_real_cast_db_py(self):
        """The real cast_db.py must contain at least the critical tables."""
        real = _SCRIPTS_DIR / "cast_db.py"
        tables = extract_allowed_tables(real)
        self.assertIn("agent_protocol_violations", tables)
        self.assertIn("agent_truncations", tables)
        self.assertIn("dispatch_decisions", tables)
        self.assertIn("injection_log", tables)


class TestScanDbWriteCalls(unittest.TestCase):
    """scan_db_write_calls() extracts table/column info from db_write() sites."""

    def _make_fixture(self, tmpdir: Path, name: str, content: str) -> Path:
        p = tmpdir / name
        p.write_text(content)
        return p

    # ── case (a): literal dict → columns proven ──────────────────────────────
    def test_literal_dict_columns_extracted(self):
        """db_write('t', {'a':1,'b':2}) → a,b in dynamic_col_writers['t']."""
        known_tables = {"mytable"}
        allowed_tables = {"mytable"}
        with tempfile.TemporaryDirectory() as d:
            tmpdir = Path(d)
            self._make_fixture(tmpdir, "fixture.py", textwrap.dedent("""\
                db_write('mytable', {'col_a': 1, 'col_b': 'hello'})
            """))
            dynamic_tables, dynamic_col_writers = scan_db_write_calls(
                tmpdir, Path("/nonexistent/bin/cast"), allowed_tables, known_tables
            )
        self.assertIn("mytable", dynamic_tables)
        self.assertIn("col_a", dynamic_col_writers.get("mytable", {}))
        self.assertIn("col_b", dynamic_col_writers.get("mytable", {}))

    def test_literal_dict_double_quotes(self):
        """db_write("t", {"a": 1}) also works."""
        known_tables = {"tbl"}
        allowed_tables = {"tbl"}
        with tempfile.TemporaryDirectory() as d:
            tmpdir = Path(d)
            self._make_fixture(tmpdir, "fixture.py", textwrap.dedent("""\
                db_write("tbl", {"x_col": val, "y_col": val2})
            """))
            dynamic_tables, dynamic_col_writers = scan_db_write_calls(
                tmpdir, Path("/nonexistent/bin/cast"), allowed_tables, known_tables
            )
        self.assertIn("tbl", dynamic_tables)
        self.assertIn("x_col", dynamic_col_writers.get("tbl", {}))
        self.assertIn("y_col", dynamic_col_writers.get("tbl", {}))

    def test_cast_db_prefix_recognised(self):
        """cast_db.db_write('tbl', row) registers tbl as a dynamic table."""
        known_tables = {"evtbl"}
        allowed_tables = {"evtbl"}
        with tempfile.TemporaryDirectory() as d:
            tmpdir = Path(d)
            self._make_fixture(tmpdir, "fixture.py", textwrap.dedent("""\
                cast_db.db_write('evtbl', row)
            """))
            dynamic_tables, dynamic_col_writers = scan_db_write_calls(
                tmpdir, Path("/nonexistent/bin/cast"), allowed_tables, known_tables
            )
        self.assertIn("evtbl", dynamic_tables)

    # ── case (b): non-literal payload → table registered, cols not proven ─────
    def test_non_literal_payload_registers_table_only(self):
        """db_write('t', payload) → t in dynamic_tables, no cols extracted."""
        known_tables = {"dyntbl"}
        allowed_tables = {"dyntbl"}
        with tempfile.TemporaryDirectory() as d:
            tmpdir = Path(d)
            self._make_fixture(tmpdir, "fixture.sh", textwrap.dedent("""\
                db_write('dyntbl', payload)
            """))
            dynamic_tables, dynamic_col_writers = scan_db_write_calls(
                tmpdir, Path("/nonexistent/bin/cast"), allowed_tables, known_tables
            )
        self.assertIn("dyntbl", dynamic_tables)
        self.assertEqual(dynamic_col_writers.get("dyntbl", {}), {})

    def test_allowed_tables_always_in_dynamic_tables(self):
        """Tables in ALLOWED_TABLES are dynamic_tables even with no call found."""
        known_tables = {"no_call_tbl"}
        allowed_tables = {"no_call_tbl"}
        with tempfile.TemporaryDirectory() as d:
            tmpdir = Path(d)
            # No db_write call in this file
            self._make_fixture(tmpdir, "unrelated.py", "print('hello')\n")
            dynamic_tables, _ = scan_db_write_calls(
                tmpdir, Path("/nonexistent/bin/cast"), allowed_tables, known_tables
            )
        self.assertIn("no_call_tbl", dynamic_tables)

    # ── case (c): unknown table not in ALLOWED_TABLES ─────────────────────────
    def test_unknown_table_not_promoted(self):
        """Tables not in ALLOWED_TABLES and not in known_tables stay out."""
        known_tables = {"real_table"}
        allowed_tables = set()  # empty — no dynamic writer
        with tempfile.TemporaryDirectory() as d:
            tmpdir = Path(d)
            self._make_fixture(tmpdir, "fixture.py", "db_write('ghost_table', {})\n")
            dynamic_tables, dynamic_col_writers = scan_db_write_calls(
                tmpdir, Path("/nonexistent/bin/cast"), allowed_tables, known_tables
            )
        self.assertNotIn("ghost_table", dynamic_tables)


class TestColumnContractClassification(unittest.TestCase):
    """ColumnContract.classification respects dynamic writer fields."""

    def _col(self, **kwargs) -> ColumnContract:
        defaults = dict(
            table="t",
            column="c",
            declared_in_init=True,
            migration_added=False,
            migration_dropped=False,
        )
        defaults.update(kwargs)
        return ColumnContract(**defaults)

    # ── case (a): literal db_write column → KEEP ──────────────────────────────
    def test_literal_dbwrite_col_is_keep(self):
        """A column in dynamic_writer_cols must classify as KEEP."""
        c = self._col(dynamic_writer_cols=["c"])
        self.assertEqual(c.classification, "KEEP")

    def test_literal_dbwrite_col_overrides_safe_drop(self):
        """dynamic_writer_cols KEEP must win over the SAFE-DROP-CANDIDATE default."""
        # No script_writers, no script_readers, but dynamic_writer_cols has 'c'
        c = self._col(script_writers=[], script_readers=[], dynamic_writer_cols=["c"])
        self.assertNotEqual(c.classification, "SAFE-DROP-CANDIDATE")
        self.assertEqual(c.classification, "KEEP")

    # ── case (b): dynamic writer table → KEEP (columns unproven) ─────────────
    def test_dynamic_writer_table_col_is_keep(self):
        """A column in a dynamic_writer_table table must classify as KEEP."""
        c = self._col(dynamic_writer_table=True)
        self.assertEqual(c.classification, "KEEP")

    def test_dynamic_writer_table_col_not_safe_drop(self):
        """No script_writers + dynamic_writer_table → KEEP, not SAFE-DROP."""
        c = self._col(
            script_writers=[], script_readers=[], dynamic_writer_table=True
        )
        self.assertNotEqual(c.classification, "SAFE-DROP-CANDIDATE")

    def test_dynamic_writer_table_with_reader_not_fix_writer(self):
        """If table is dynamic_writer_table, a reader shouldn't make it FIX-WRITER."""
        c = self._col(
            script_writers=[],
            script_readers=["scripts/reader.py"],
            dynamic_writer_table=True,
        )
        self.assertNotEqual(c.classification, "FIX-WRITER")
        self.assertEqual(c.classification, "KEEP")

    # ── case (c): non-ALLOWED table with reader → FIX-WRITER (no false KEEP) ──
    def test_reader_no_writer_no_dynamic_is_fix_writer(self):
        """Reader + no writer + no dynamic_writer → FIX-WRITER (unchanged)."""
        c = self._col(
            script_writers=[],
            script_readers=["scripts/reader.py"],
            dynamic_writer_table=False,
            dynamic_writer_cols=[],
        )
        self.assertEqual(c.classification, "FIX-WRITER")

    def test_no_evidence_no_dynamic_is_safe_drop(self):
        """No writers, no readers, no dynamic writer → SAFE-DROP-CANDIDATE."""
        c = self._col(
            script_writers=[],
            script_readers=[],
            dynamic_writer_table=False,
            dynamic_writer_cols=[],
        )
        self.assertEqual(c.classification, "SAFE-DROP-CANDIDATE")

    # ── CONTRADICTION/DESKTOP-COUPLED still take precedence ───────────────────
    def test_contradiction_overrides_dynamic_writer(self):
        """CONTRADICTION takes priority even when dynamic_writer_table is True."""
        c = self._col(
            declared_in_init=True,
            migration_dropped=True,
            dynamic_writer_table=True,
        )
        self.assertEqual(c.classification, "CONTRADICTION")

    def test_desktop_coupled_overrides_dynamic_writer(self):
        """DESKTOP-COUPLED takes priority over dynamic_writer_table."""
        c = self._col(
            desktop_readers=["cast-desktop/server/routes/foo.ts"],
            desktop_checked=True,
            dynamic_writer_table=True,
        )
        self.assertEqual(c.classification, "DESKTOP-COUPLED")


class TestReadAttributionNoMisattribution(unittest.TestCase):
    """Regression tests for read-attribution false-positive fixes.

    The checker read-attribution fix was applied to _parse_sql_ops to prevent
    misattributing column reads to the wrong table. These tests lock in the
    correct behavior so the 5 false-positives never regress.
    """

    def test_confidence_not_misattributed_from_agent_runs(self):
        """confidence: sql joining should not misattribute column to agent_runs.

        Previously, COALESCE(SUM(cost_usd),0) FROM agent_runs would cause
        'confidence' from the next SELECT to be misattributed as agent_runs reader.
        """
        sql = (
            "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs WHERE date(started_at)>=?\n"
            "SELECT COUNT(*) FROM agent_memories WHERE confidence < 0.4"
        )
        known_tables = {"agent_runs", "agent_memories"}
        writers, readers = _parse_sql_ops(sql, known_tables)

        # confidence should NOT be in agent_runs readers (was misattributed)
        self.assertNotIn("confidence", readers.get("agent_runs", set()))
        # confidence SHOULD be in agent_memories readers
        self.assertIn("confidence", readers.get("agent_memories", set()))

    def test_title_not_misattributed_from_agent_truncations(self):
        """title: f-string placeholder should not cause misattribution.

        An f-string "FROM {child} WHERE 1=1" followed by Python comment/code
        should not cause 'title' to be misattributed as agent_truncations reader.
        """
        sql = (
            "SELECT count(*) FROM {child} WHERE 1=1\n"
            "CheckResult(cid, title, 'error')\n"
            "SELECT id FROM agent_truncations WHERE agent_type LIKE ? ORDER BY id DESC LIMIT ?"
        )
        known_tables = {"agent_truncations"}
        writers, readers = _parse_sql_ops(sql, known_tables)

        # title should NOT be in agent_truncations readers (was misattributed)
        self.assertNotIn("title", readers.get("agent_truncations", set()))

    def test_eval_runs_eval_id_not_leaked_to_routing_events(self):
        """eval_runs (eval_id): eval_id should not bleed to routing_events.

        An INNER JOIN with a subquery should not cause eval_id from eval_runs
        to be misattributed as a routing_events reader when routing_events is
        in known_tables but not actually referenced in this statement.
        """
        sql = (
            "SELECT r.eval_id, r.agent, r.ended_at FROM eval_runs r "
            "INNER JOIN (SELECT eval_id, MAX(ended_at) AS max_ended FROM eval_runs "
            "GROUP BY eval_id) latest ON r.eval_id=latest.eval_id AND "
            "r.ended_at=latest.max_ended WHERE r.eval_id=?"
        )
        known_tables = {"eval_runs", "routing_events"}
        writers, readers = _parse_sql_ops(sql, known_tables)

        # eval_id should NOT be in routing_events readers
        self.assertNotIn("eval_id", readers.get("routing_events", set()))
        # But eval_id SHOULD be in eval_runs readers
        self.assertIn("eval_id", readers.get("eval_runs", set()))

    def test_eval_runs_ended_at_not_leaked_to_routing_events(self):
        """eval_runs (ended_at): ended_at should not bleed to routing_events.

        An INNER JOIN with a subquery should not cause ended_at from eval_runs
        to be misattributed as a routing_events reader when routing_events is
        in known_tables but not actually referenced in this statement.
        """
        sql = (
            "SELECT r.eval_id, r.agent, r.ended_at FROM eval_runs r "
            "INNER JOIN (SELECT eval_id, MAX(ended_at) AS max_ended FROM eval_runs "
            "GROUP BY eval_id) latest ON r.eval_id=latest.eval_id AND "
            "r.ended_at=latest.max_ended WHERE r.eval_id=?"
        )
        known_tables = {"eval_runs", "routing_events"}
        writers, readers = _parse_sql_ops(sql, known_tables)

        # ended_at should NOT be in routing_events readers
        self.assertNotIn("ended_at", readers.get("routing_events", set()))
        # But ended_at SHOULD be in eval_runs readers
        self.assertIn("ended_at", readers.get("eval_runs", set()))

    def test_session_id_not_misattributed_from_sessions(self):
        """session_id: SELECT AS renaming should not confuse attribution.

        "SELECT id AS session_id FROM sessions" should not cause session_id
        to be incorrectly added as a reader of the sessions table. The renamed
        alias is not a column read; only actual column reads should be attributed.
        """
        sql = (
            "SELECT id AS session_id FROM sessions WHERE id = ? LIMIT 1\n"
            "SELECT COALESCE(SUM(input_tokens),0) FROM agent_runs WHERE session_id = ?"
        )
        known_tables = {"sessions", "agent_runs"}
        writers, readers = _parse_sql_ops(sql, known_tables)

        # session_id should NOT be in sessions readers (it's a renamed alias, not a read)
        self.assertNotIn("session_id", readers.get("sessions", set()))
        # But session_id SHOULD be in agent_runs readers
        self.assertIn("session_id", readers.get("agent_runs", set()))


class TestParseAutoPopulated(unittest.TestCase):
    """parse_auto_populated() identifies schema-engine-populated columns."""

    def _write_init(self, content: str) -> Path:
        f = tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False)
        f.write(content)
        f.flush()
        f.close()
        return Path(f.name)

    def tearDown(self):
        # Clean up any temp files leaked by individual tests
        pass

    def test_autoincrement_col_is_auto_populated(self):
        """id INTEGER PRIMARY KEY AUTOINCREMENT with no writer → KEEP (not SAFE-DROP)."""
        init = self._write_init(textwrap.dedent("""\
            sqlite3 "$DB" <<'SQL'
            CREATE TABLE IF NOT EXISTS otel_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT
            );
            SQL
        """))
        try:
            result = parse_auto_populated(init)
            self.assertIn("id", result.get("otel_events", set()))
            self.assertNotIn("name", result.get("otel_events", set()))
        finally:
            init.unlink()

    def test_default_clause_col_is_auto_populated(self):
        """received_at TEXT DEFAULT (datetime('now')) → auto-populated."""
        init = self._write_init(textwrap.dedent("""\
            sqlite3 "$DB" <<'SQL'
            CREATE TABLE IF NOT EXISTS otel_metrics (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              received_at TEXT DEFAULT (datetime('now')),
              metric_name TEXT
            );
            SQL
        """))
        try:
            result = parse_auto_populated(init)
            self.assertIn("id", result.get("otel_metrics", set()))
            self.assertIn("received_at", result.get("otel_metrics", set()))
            self.assertNotIn("metric_name", result.get("otel_metrics", set()))
        finally:
            init.unlink()

    def test_alter_table_default_col_is_auto_populated(self):
        """ALTER TABLE t ADD COLUMN outcome TEXT DEFAULT 'pending' → auto-populated."""
        init = self._write_init(textwrap.dedent("""\
            ALTER TABLE dispatch_decisions ADD COLUMN outcome TEXT DEFAULT 'pending';
        """))
        try:
            result = parse_auto_populated(init)
            self.assertIn("outcome", result.get("dispatch_decisions", set()))
        finally:
            init.unlink()

    def test_plain_col_not_auto_populated(self):
        """Columns without AUTOINCREMENT/DEFAULT/PRIMARY KEY are not auto-populated."""
        init = self._write_init(textwrap.dedent("""\
            sqlite3 "$DB" <<'SQL'
            CREATE TABLE IF NOT EXISTS plain_tbl (
              name TEXT,
              value TEXT
            );
            SQL
        """))
        try:
            result = parse_auto_populated(init)
            self.assertEqual(result.get("plain_tbl", set()), set())
        finally:
            init.unlink()


class TestParseContractDirectives(unittest.TestCase):
    """parse_contract_directives() parses -- db-contract: comment annotations."""

    def _write_init(self, content: str) -> Path:
        f = tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False)
        f.write(content)
        f.flush()
        f.close()
        return Path(f.name)

    def test_external_writer_directive_parsed(self):
        """-- db-contract: external-writer table=attestations source=attest parses correctly."""
        init = self._write_init(
            "-- db-contract: external-writer table=attestations source=attest\n"
        )
        try:
            result = parse_contract_directives(init)
            self.assertIn("attestations", result)
            self.assertEqual(result["attestations"]["kind"], "external-writer")
            self.assertEqual(result["attestations"]["source"], "attest")
        finally:
            init.unlink()

    def test_reserved_directive_parsed(self):
        """-- db-contract: reserved table=foo registers kind=reserved with no source."""
        init = self._write_init(
            "-- db-contract: reserved table=foo\n"
        )
        try:
            result = parse_contract_directives(init)
            self.assertIn("foo", result)
            self.assertEqual(result["foo"]["kind"], "reserved")
            self.assertIsNone(result["foo"]["source"])
        finally:
            init.unlink()

    def test_line_missing_table_token_is_skipped(self):
        """A directive line without table= is silently skipped."""
        init = self._write_init(
            "-- db-contract: reserved source=attest\n"
        )
        try:
            result = parse_contract_directives(init)
            self.assertEqual(result, {})
        finally:
            init.unlink()

    def test_duplicate_table_last_wins(self):
        """If a table appears in two directives, the last one wins."""
        init = self._write_init(textwrap.dedent("""\
            -- db-contract: reserved table=bar
            -- db-contract: external-writer table=bar source=toolx
        """))
        try:
            result = parse_contract_directives(init)
            self.assertEqual(result["bar"]["kind"], "external-writer")
        finally:
            init.unlink()

    def test_case_insensitive_kind(self):
        """Directive kind matching is case-insensitive."""
        init = self._write_init(
            "-- db-contract: RESERVED table=baz\n"
        )
        try:
            result = parse_contract_directives(init)
            self.assertEqual(result["baz"]["kind"], "reserved")
        finally:
            init.unlink()


class TestAutoPopulatedClassification(unittest.TestCase):
    """ColumnContract.classification treats auto_populated cols as KEEP."""

    def _col(self, **kwargs) -> ColumnContract:
        defaults = dict(
            table="t",
            column="c",
            declared_in_init=True,
            migration_added=False,
            migration_dropped=False,
        )
        defaults.update(kwargs)
        return ColumnContract(**defaults)

    def test_autoincrement_no_writer_is_keep(self):
        """id with AUTOINCREMENT and no writer → KEEP, not SAFE-DROP-CANDIDATE."""
        c = self._col(column="id", auto_populated=True,
                      script_writers=[], script_readers=[])
        self.assertEqual(c.classification, "KEEP")

    def test_default_col_no_writer_is_keep(self):
        """received_at with DEFAULT and no writer → KEEP, not SAFE-DROP-CANDIDATE."""
        c = self._col(column="received_at", auto_populated=True,
                      script_writers=[], script_readers=[])
        self.assertEqual(c.classification, "KEEP")

    def test_auto_populated_does_not_override_contradiction(self):
        """CONTRADICTION wins over auto_populated=True."""
        c = self._col(
            declared_in_init=True,
            migration_dropped=True,
            auto_populated=True,
        )
        self.assertEqual(c.classification, "CONTRADICTION")


class TestProvenanceClassification(unittest.TestCase):
    """ColumnContract.classification honours provenance directives."""

    def _col(self, **kwargs) -> ColumnContract:
        defaults = dict(
            table="t",
            column="c",
            declared_in_init=True,
            migration_added=False,
            migration_dropped=False,
        )
        defaults.update(kwargs)
        return ColumnContract(**defaults)

    def test_reserved_directive_classifies_declared_reserved(self):
        """provenance='reserved' + unwritten col → DECLARED-RESERVED."""
        c = self._col(provenance="reserved",
                      script_writers=[], script_readers=[])
        self.assertEqual(c.classification, "DECLARED-RESERVED")

    def test_external_writer_directive_classifies_external_writer(self):
        """provenance='external-writer' + unwritten col → EXTERNAL-WRITER."""
        c = self._col(provenance="external-writer",
                      script_writers=[], script_readers=[])
        self.assertEqual(c.classification, "EXTERNAL-WRITER")

    def test_directive_does_not_override_contradiction(self):
        """CONTRADICTION wins even when provenance is set."""
        # Script references an undeclared column → CONTRADICTION
        c = self._col(
            declared_in_init=False,
            migration_added=False,
            script_writers=["scripts/foo.py"],
            provenance="reserved",
        )
        self.assertEqual(c.classification, "CONTRADICTION")

    def test_real_writer_wins_over_reserved_directive(self):
        """A column with a real script writer stays KEEP even on a reserved table."""
        c = self._col(
            script_writers=["scripts/foo.py"],
            provenance="reserved",
        )
        self.assertEqual(c.classification, "KEEP")

    def test_real_writer_wins_over_external_writer_directive(self):
        """A column with a real script writer stays KEEP on an external-writer table."""
        c = self._col(
            script_writers=["scripts/attest.py"],
            provenance="external-writer",
        )
        self.assertEqual(c.classification, "KEEP")

    def test_dynamic_writer_table_wins_over_reserved(self):
        """dynamic_writer_table=True keeps KEEP priority over reserved directive."""
        c = self._col(
            dynamic_writer_table=True,
            provenance="reserved",
            script_writers=[],
        )
        self.assertEqual(c.classification, "KEEP")


if __name__ == "__main__":
    unittest.main()
