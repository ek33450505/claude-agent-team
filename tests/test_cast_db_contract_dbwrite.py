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
ColumnContract = _mod.ColumnContract


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


if __name__ == "__main__":
    unittest.main()
