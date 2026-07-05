#!/usr/bin/env python3
"""cast-db-contract.py — Schema/DB-contract reconciliation tool.

Diffs four sources per table/column and classifies each column:
  KEEP              — actively written by CAST scripts (with or without readers)
  DESKTOP-COUPLED   — read by cast-desktop server SQL; overrides everything
  FIX-WRITER        — read by CAST scripts but no writer found
  SAFE-DROP-CANDIDATE — no writer, no reader, not desktop-read
  CONTRADICTION     — declared-in-init + migration-dropped, OR
                      referenced in scripts but never declared

Ratchet decision: --check uses a committed baseline file
(.github/db-contract-baseline.json) and exits 1 only on NEW entries
absent from that baseline. This is simpler and more deterministic than a
time-based grace window (clock-skew-free, rebase-safe).

Desktop-absent ratchet: when cast-desktop is not reachable (UNCHECKED),
--check ratchets CONTRADICTIONS only and SKIPS safe-drop-candidate
ratcheting. Reason: without the desktop source, columns that would be
DESKTOP-COUPLED (and therefore NOT SAFE-DROP) degrade to SAFE-DROP-CANDIDATE.
Ratcheting those as "new" safe-drops would produce false CI failures.
The --check output always states which mode is active — it never silently
changes scope. "Unreachable" is never treated as "no reads" (CAST
honest-degradation principle).

Usage:
  scripts/cast-db-contract.py [--json] [--db PATH] [--desktop-path PATH]
                               [--check] [--update-baseline] [--baseline PATH]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ─── Constants ────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent
INIT_SCRIPT = SCRIPT_DIR / "cast-db-init.sh"
MIGRATIONS_DIR = SCRIPT_DIR / "migrations"
CAST_DB_PY = SCRIPT_DIR / "cast_db.py"
DEFAULT_DESKTOP_PATH = Path.home() / "Projects" / "personal" / "cast-desktop"
DEFAULT_BASELINE = REPO_ROOT / ".github" / "db-contract-baseline.json"
DEFAULT_DB = Path(os.environ.get("CAST_DB_PATH", str(Path.home() / ".claude" / "cast.db")))

# SQL keywords: excluded when extracting bare column names from SQL text
# Minimum identifier length and pattern for valid SQL column names.
# Requires: starts with letter or underscore, at least 2 characters.
# This filters out numeric literals (1, 0), single-letter variables (c, r, t),
# and other parsing artifacts while keeping all valid CAST column names.
_COL_RE = re.compile(r"^[a-zA-Z]\w+$")

# Permissive bare-word matcher for validating REAL schema identifiers
# (table/column names from sqlite_master/PRAGMA), where single-char names
# like FTS config's `k`/`v` are legitimate — unlike _COL_RE, which is a
# source-parsing heuristic that intentionally drops single letters.
_SCHEMA_IDENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\Z')

SQL_KEYWORDS = frozenset({
    "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
    "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE",
    "TABLE", "INDEX", "DROP", "ALTER", "ADD", "COLUMN", "PRIMARY",
    "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "CONSTRAINT",
    "DEFAULT", "INTEGER", "TEXT", "REAL", "BLOB", "AUTOINCREMENT",
    "IF", "EXISTS", "LIMIT", "OFFSET", "ORDER", "BY", "GROUP", "HAVING",
    "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "ON",
    "AS", "DISTINCT", "COUNT", "SUM", "MAX", "MIN", "AVG",
    "COALESCE", "CASE", "WHEN", "THEN", "ELSE", "END", "CAST",
    "LIKE", "BETWEEN", "WITH", "UNION", "ALL", "EXCEPT", "INTERSECT",
    "ROW_NUMBER", "OVER", "PARTITION", "WINDOW", "FIRST", "LAST",
    "ASC", "DESC", "NULLS", "REPLACE", "ABORT", "ROLLBACK", "FAIL",
    "NOW", "DATE", "DATETIME", "JULIANDAY", "STRFTIME", "CURRENT_TIMESTAMP",
    "TRUE", "FALSE", "TIMESTAMP", "CONFLICT", "DO", "NOTHING", "EXCLUDED",
    "PRAGMA", "CURRENT", "ROW", "ROWS", "RANGE", "PRECEDING", "FOLLOWING",
    "UNBOUNDED", "ISNULL", "NOTNULL", "GLOB", "REGEXP", "MATCH",
    "TEMP", "TEMPORARY", "VIEW", "TRIGGER", "VIRTUAL", "USING",
    "RECURSIVE", "GENERATED", "ALWAYS", "STORED",
    "LONG", "INT", "CHAR", "VARCHAR", "NUMERIC", "DOUBLE", "FLOAT",
    "BOOLEAN", "NUMBER", "DECIMAL", "NONE", "INNER",
    "ROWID", "OID", "ROWNUM", "EXCLUDE", "TIES", "OTHERS",
    "TRANSACTION", "BEGIN", "COMMIT", "SAVEPOINT", "VACUUM",
    "ATTACH", "DETACH", "ANALYZE", "EXPLAIN", "QUERY", "PLAN",
})

# Python stdlib module names that are never valid DB column names.
# Prevents false-positive CONTRADICTION entries when a .sh file embeds a
# Python heredoc that contains both `import X, Y, Z` and a SQL SELECT …
# FROM table, causing the DOTALL lazy select_re to span across the import
# line and misattribute module names as bare column reads.
# EXCLUDED from this list: 'time', 'type', 'data' — could plausibly be
# real column names (verified: none currently declared in cast-db-init.sh,
# but kept out as a precaution per denylist-design convention).
NON_COLUMN_IDENTIFIERS: frozenset[str] = frozenset({
    "os", "sys", "subprocess", "json", "re", "datetime", "sqlite3",
    "argparse", "pathlib", "glob", "typing", "dataclasses",
    "collections", "math", "random", "shutil", "tempfile", "hashlib",
    "base64", "io", "traceback", "logging", "functools", "itertools",
    "contextlib",
})

# Well-known table aliases used consistently in cast-desktop server SQL.
# Used to attribute alias.col references to the correct table.
TABLE_ALIASES: dict[str, str] = {
    "ar": "agent_runs",
    "s":  "sessions",
    "r":  "routing_events",
    "m":  "agent_memories",
    "q":  "quality_gates",
    "d":  "dispatch_decisions",
}


# ─── Data Classes ─────────────────────────────────────────────────────────────

@dataclass
class ColumnContract:
    table: str
    column: str
    declared_in_init: bool
    migration_added: bool
    migration_dropped: bool
    script_writers: list[str] = field(default_factory=list)
    script_readers: list[str] = field(default_factory=list)
    desktop_readers: list[str] = field(default_factory=list)
    desktop_checked: bool = True   # False when desktop repo is absent
    fill_rate: Optional[float] = None
    db_checked: bool = False
    # Dynamic-writer fields: populated by scan_db_write_calls()
    dynamic_writer_table: bool = False   # table is in ALLOWED_TABLES or any db_write call
    dynamic_writer_cols: list[str] = field(default_factory=list)  # cols proven via literal dict
    # Schema-population fields: populated by parse_auto_populated() / parse_contract_directives()
    auto_populated: bool = False         # column has AUTOINCREMENT / PRIMARY KEY / DEFAULT in schema
    provenance: Optional[str] = None     # 'reserved' | 'external-writer' | None

    @property
    def classification(self) -> str:
        """Classify column based on available evidence.

        Priority order (highest wins):
          1. CONTRADICTION — init-declared but migration-dropped, OR
             referenced in scripts but never declared anywhere
          2. DESKTOP-COUPLED — desktop reads it (only when desktop is reachable)
          3. KEEP — at least one CAST script writer found, OR column proven
             via a literal db_write dict
          4. KEEP (dynamic) — table is a db_write target (ALLOWED_TABLES or
             call-site found); columns written at runtime, unproven at column
             granularity — honest KEEP, not implying a literal writer
          5. FIX-WRITER — read by scripts but no writer and not a dynamic-writer
             table (the table is not a db_write target)
          6. SAFE-DROP-CANDIDATE — nothing writes or reads it and table is not
             a dynamic-writer target
        """
        # CONTRADICTION: init declares it but migration drops it → init is stale
        if self.declared_in_init and self.migration_dropped:
            return "CONTRADICTION"
        # CONTRADICTION: scripts reference a column that no declaration covers
        if (self.script_writers or self.script_readers) and \
                not self.declared_in_init and not self.migration_added:
            return "CONTRADICTION"
        # DESKTOP-COUPLED overrides (only when desktop was reachable)
        if self.desktop_readers and self.desktop_checked:
            return "DESKTOP-COUPLED"
        # KEEP: at least one literal SQL writer (INSERT/UPDATE) found
        if self.script_writers:
            return "KEEP"
        # KEEP: column proven via a literal db_write({'col': ...}) call
        if self.column in self.dynamic_writer_cols:
            return "KEEP"
        # KEEP (dynamic): table is a db_write target; column is written at
        # runtime. We don't have column-level proof, but the table is in
        # ALLOWED_TABLES or has a confirmed db_write call site. Mark KEEP so
        # the tool never proposes dropping a live dynamic-writer column.
        if self.dynamic_writer_table:
            return "KEEP"
        # Provenance directive from cast-db-init.sh (machine-readable -- db-contract: ...).
        # Upgrades what would otherwise be SAFE-DROP/FIX-WRITER. Never masks CONTRADICTION
        # (checked first) or a real writer (KEEP, checked above).
        if self.provenance == "external-writer":
            return "EXTERNAL-WRITER"
        if self.provenance == "reserved":
            return "DECLARED-RESERVED"
        # Auto-populated by the schema (AUTOINCREMENT / INTEGER PRIMARY KEY / DEFAULT):
        # never written by application code, but never an orphan.
        if self.auto_populated:
            return "KEEP"
        # FIX-WRITER: something reads it but nothing writes it
        if self.script_readers and not self.script_writers:
            return "FIX-WRITER"
        # SAFE-DROP-CANDIDATE: no evidence of use
        return "SAFE-DROP-CANDIDATE"

    def to_dict(self) -> dict:
        return {
            "table": self.table,
            "column": self.column,
            "classification": self.classification,
            "declared_in_init": self.declared_in_init,
            "migration_added": self.migration_added,
            "migration_dropped": self.migration_dropped,
            "script_writers": sorted(self.script_writers),
            "script_readers": sorted(self.script_readers),
            "desktop_readers": sorted(self.desktop_readers),
            "desktop_checked": self.desktop_checked,
            "fill_rate": self.fill_rate,
            "db_checked": self.db_checked,
            "dynamic_writer_table": self.dynamic_writer_table,
            "dynamic_writer_cols": sorted(self.dynamic_writer_cols),
            "auto_populated": self.auto_populated,
            "provenance": self.provenance,
        }


# ─── Source Extraction: init schema ───────────────────────────────────────────

def _strip_sql_line_comments(sql: str) -> str:
    """Strip SQL '--' line comments (everything from '--' to end of line).

    Used before CREATE TABLE regex runs so that prose comments containing
    'CREATE TABLE foo (' do not produce phantom table entries.
    """
    return re.sub(r"--[^\n]*", "", sql)


def parse_init_schema(init_path: Path) -> dict[str, set[str]]:
    """Parse CREATE TABLE blocks and ALTER TABLE ADD COLUMN from cast-db-init.sh.

    Returns {table_name: set[column_name]}. Unions columns from all CREATE TABLE
    blocks for the same table (the init has multiple version-gated blocks).
    """
    try:
        content = init_path.read_text(errors="replace")
    except OSError as e:
        print(f"[ERROR] Cannot read {init_path}: {e}", file=sys.stderr)
        return {}

    # Strip '--' line comments so prose comments containing 'CREATE TABLE foo ('
    # do not produce phantom table entries in the schema dict.
    content_sql = _strip_sql_line_comments(content)

    schema: dict[str, set[str]] = {}
    table_re = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(",
        re.IGNORECASE,
    )
    for match in table_re.finditer(content_sql):
        table = match.group(1).lower()
        block = _extract_paren_block(content_sql, match.end())
        cols = _parse_create_table_columns(block)
        schema.setdefault(table, set()).update(cols)

    # Self-healing ALTER TABLE ADD COLUMN in the init also constitutes a declaration
    for m in re.finditer(
        r"ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)",
        content_sql, re.IGNORECASE,
    ):
        schema.setdefault(m.group(1).lower(), set()).add(m.group(2).lower())

    return schema


def _extract_paren_block(content: str, start: int) -> str:
    """Return the text between the opening '(' at start and its matching ')'."""
    depth = 1
    pos = start
    while pos < len(content) and depth > 0:
        ch = content[pos]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        pos += 1
    return content[start : pos - 1]


def _parse_create_table_columns(block: str) -> set[str]:
    """Extract column names from a CREATE TABLE body block."""
    cols: set[str] = set()
    skip_prefixes = frozenset({
        "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "CONSTRAINT",
        "CREATE", "ALTER", "DROP", "INSERT", "UPDATE", "SELECT", "PRAGMA",
    })
    for line in block.split("\n"):
        stripped = line.strip().rstrip(",")
        if not stripped or stripped.startswith("--"):
            continue
        first = stripped.split()[0].upper() if stripped.split() else ""
        if first in skip_prefixes:
            continue
        m = re.match(r"^(\w+)\s", stripped)
        if m:
            col = m.group(1).lower()
            if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
                cols.add(col)
    return cols


def parse_auto_populated(init_path: Path) -> dict[str, set[str]]:
    """Parse auto-populated columns from CREATE TABLE and ALTER TABLE in cast-db-init.sh.

    A column is considered auto-populated when its definition line in a CREATE TABLE
    block carries AUTOINCREMENT, INTEGER PRIMARY KEY (implicit rowid alias), or a
    DEFAULT clause — meaning the DB engine populates it and app code never writes it.

    Also handles ALTER TABLE ... ADD COLUMN lines that carry a DEFAULT clause.

    Returns {table_lower: set(col_lower)}.
    """
    try:
        content = init_path.read_text(errors="replace")
    except OSError as e:
        print(f"[ERROR] Cannot read {init_path}: {e}", file=sys.stderr)
        return {}

    # Strip '--' line comments so prose comments containing 'CREATE TABLE foo ('
    # do not produce phantom table entries (mirrors parse_init_schema).
    content_sql = _strip_sql_line_comments(content)

    auto_populated: dict[str, set[str]] = {}
    _auto_re = re.compile(
        r"\bAUTOINCREMENT\b|\bDEFAULT\b|\bPRIMARY\s+KEY\b",
        re.IGNORECASE,
    )
    skip_prefixes = frozenset({
        "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "CONSTRAINT",
        "CREATE", "ALTER", "DROP", "INSERT", "UPDATE", "SELECT", "PRAGMA",
    })

    table_re = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(",
        re.IGNORECASE,
    )
    for match in table_re.finditer(content_sql):
        table = match.group(1).lower()
        block = _extract_paren_block(content_sql, match.end())
        for line in block.split("\n"):
            stripped = line.strip().rstrip(",")
            if not stripped or stripped.startswith("--"):
                continue
            first = stripped.split()[0].upper() if stripped.split() else ""
            if first in skip_prefixes:
                continue
            col_m = re.match(r"^(\w+)\s", stripped)
            if col_m:
                col = col_m.group(1).lower()
                if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
                    if _auto_re.search(stripped):
                        auto_populated.setdefault(table, set()).add(col)

    # ALTER TABLE ... ADD COLUMN col TYPE ... DEFAULT ...
    for m in re.finditer(
        r"ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)([^\n]*)",
        content_sql, re.IGNORECASE,
    ):
        if re.search(r"\bDEFAULT\b", m.group(3), re.IGNORECASE):
            table = m.group(1).lower()
            col = m.group(2).lower()
            auto_populated.setdefault(table, set()).add(col)

    return auto_populated


def parse_contract_directives(init_path: Path) -> dict[str, dict]:
    """Parse machine-readable db-contract directives from cast-db-init.sh.

    Recognises two directive forms on comment lines:
      -- db-contract: reserved table=<t>
      -- db-contract: external-writer table=<t> source=<name>

    Returns {table_lower: {'kind': 'reserved'|'external-writer', 'source': str|None}}.
    If a table name appears more than once, the last directive wins.
    Lines that are missing the required ``table=`` token are silently skipped.
    """
    try:
        content = init_path.read_text(errors="replace")
    except OSError as e:
        print(f"[ERROR] Cannot read {init_path}: {e}", file=sys.stderr)
        return {}

    directives: dict[str, dict] = {}
    kind_re = re.compile(
        r"--\s*db-contract:\s*(reserved|external-writer)\b",
        re.IGNORECASE,
    )
    table_token_re = re.compile(r"\btable=(\w+)", re.IGNORECASE)
    source_token_re = re.compile(r"\bsource=(\S+)", re.IGNORECASE)

    for line in content.splitlines():
        kind_m = kind_re.search(line)
        if not kind_m:
            continue
        kind = kind_m.group(1).lower()
        tbl_m = table_token_re.search(line)
        if not tbl_m:
            continue  # table= is required; skip silently
        table = tbl_m.group(1).lower()
        src_m = source_token_re.search(line)
        directives[table] = {
            "kind": kind,
            "source": src_m.group(1) if src_m else None,
        }

    return directives


# ─── Source Extraction: migrations ────────────────────────────────────────────

def parse_migrations(
    migrations_dir: Path,
) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Parse SQL migration files for net column additions and drops.

    Returns (added, dropped):
      added   — {table: set of columns added by any migration (net)}
      dropped — {table: set of columns dropped by any migration (net)}
    Re-adds cancel previous drops and vice-versa.
    """
    added: dict[str, set[str]] = {}
    dropped: dict[str, set[str]] = {}

    try:
        sql_files = sorted(
            f for f in migrations_dir.iterdir()
            if f.suffix == ".sql" and f.is_file()
        )
    except OSError:
        return added, dropped

    add_re = re.compile(
        r"ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)", re.IGNORECASE
    )
    drop_re = re.compile(
        r"ALTER\s+TABLE\s+(\w+)\s+DROP\s+COLUMN\s+(\w+)", re.IGNORECASE
    )
    table_re = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(", re.IGNORECASE
    )

    for sql_file in sql_files:
        try:
            content = sql_file.read_text(errors="replace")
        except OSError:
            continue

        # Strip '--' line comments so prose comments containing 'CREATE TABLE foo ('
        # (e.g. explanatory headers in migration files) do not produce phantom tables.
        content_sql = _strip_sql_line_comments(content)

        # CREATE TABLE in migrations: track columns
        for match in table_re.finditer(content_sql):
            table = match.group(1).lower()
            block = _extract_paren_block(content_sql, match.end())
            for col in _parse_create_table_columns(block):
                added.setdefault(table, set()).add(col)
                dropped.get(table, set()).discard(col)

        # ADD COLUMN
        for m in add_re.finditer(content_sql):
            table, col = m.group(1).lower(), m.group(2).lower()
            added.setdefault(table, set()).add(col)
            dropped.get(table, set()).discard(col)

        # DROP COLUMN
        for m in drop_re.finditer(content_sql):
            table, col = m.group(1).lower(), m.group(2).lower()
            dropped.setdefault(table, set()).add(col)
            added.get(table, set()).discard(col)

    return added, dropped


# ─── SQL Extraction from Files ────────────────────────────────────────────────

def _extract_sql_fragments(content: str) -> list[str]:
    """Extract likely SQL text from a file's content.

    Captures: full content, Python triple-quoted strings, shell heredocs,
    TypeScript backtick template literals, long quoted strings.
    Passing the full content ensures no SQL is missed at the cost of
    more noise (false-positive "is used" is the desired bias).
    """
    frags = [content]
    frags.extend(re.findall(r'"""(.*?)"""', content, re.DOTALL))
    frags.extend(re.findall(r"'''(.*?)'''", content, re.DOTALL))
    # Shell heredocs: <<'LABEL' or <<LABEL
    frags.extend(re.findall(r"<<'?\w+'?\s*\n(.*?)\n\w+", content, re.DOTALL))
    # TypeScript backtick template literals
    frags.extend(re.findall(r"`(.*?)`", content, re.DOTALL))
    # Long single-line quoted strings (≥15 chars)
    frags.extend(re.findall(r'"([^"]{15,})"', content))
    frags.extend(re.findall(r"'([^']{15,})'", content))
    return frags


def _parse_sql_ops(
    sql: str,
    known_tables: set[str],
) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Extract (table → cols) write and read mappings from SQL text.

    Design bias: prefers false-positive "is used" over false-negative
    "is dead". A safe-drop claim must be high-confidence; use the DB
    fill-rate as a secondary signal when available.

    Returns (writers, readers).
    """
    writers: dict[str, set[str]] = {}
    readers: dict[str, set[str]] = {}
    upper = sql.upper()

    if not any(k in upper for k in ("INSERT", "UPDATE", "SELECT")):
        return writers, readers

    # ── INSERT INTO table (col, col, ...) ─────────────────────────────────────
    insert_re = re.compile(
        r"INSERT\s+(?:OR\s+\w+\s+)?INTO\s+(\w+)\s*\(([^)]+)\)",
        re.IGNORECASE,
    )
    for m in insert_re.finditer(sql):
        table = m.group(1).lower()
        if table not in known_tables:
            continue
        # Split by comma only (not whitespace) so prose comments like
        # "(created by migration 009)" don't become false column names.
        for raw in m.group(2).split(","):
            col = raw.strip().strip('"\'`').lower()
            if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
                writers.setdefault(table, set()).add(col)

    # ── UPDATE table SET col = ... ─────────────────────────────────────────────
    # Limit SET clause to 600 chars to prevent DOTALL from consuming Python code
    # when the UPDATE block has no explicit WHERE or semicolon terminator nearby.
    update_re = re.compile(
        r"UPDATE\s+(\w+)\s+SET\s+(.{1,600}?)(?=\bWHERE\b|;|$)",
        re.IGNORECASE | re.DOTALL,
    )
    for m in update_re.finditer(sql):
        table = m.group(1).lower()
        if table not in known_tables:
            continue
        for cm in re.finditer(r"(?:^|,|\s)(\w+)\s*=", m.group(2)):
            col = cm.group(1).lower()
            if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
                writers.setdefault(table, set()).add(col)

    # ── ON CONFLICT (...) DO UPDATE SET col = excluded.col ────────────────────
    # Limit to 600 chars for the same reason as above.
    upsert_re = re.compile(
        r"ON\s+CONFLICT\s*\([^)]+\)\s+DO\s+UPDATE\s+SET\s+(.{1,600}?)(?=;|$)",
        re.IGNORECASE | re.DOTALL,
    )
    for m in upsert_re.finditer(sql):
        # Attribute to the nearest preceding INSERT table
        preceding = re.findall(
            r"INSERT\s+(?:OR\s+\w+\s+)?INTO\s+(\w+)", sql[: m.start()], re.IGNORECASE
        )
        if not preceding:
            continue
        table = preceding[-1].lower()
        if table not in known_tables:
            continue
        for cm in re.finditer(r"(?:^|,|\s)(\w+)\s*=", m.group(1)):
            col = cm.group(1).lower()
            if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
                writers.setdefault(table, set()).add(col)

    # ── SELECT cols FROM table [alias] / JOIN ... ──────────────────────────────
    # Strategy: find each SELECT...FROM statement, build an alias map, then
    # extract column references from both the SELECT list and WHERE/ON clauses.
    select_re = re.compile(
        r"SELECT\s+(.*?)\s+FROM\s+(\w+)(?:\s+(?:AS\s+)?(\w+))?",
        re.IGNORECASE | re.DOTALL,
    )
    join_re = re.compile(
        r"\b(?:LEFT|RIGHT|INNER|OUTER|FULL|CROSS)?\s*JOIN\s+(\w+)"
        r"(?:\s+(?:AS\s+)?(\w+))?",
        re.IGNORECASE,
    )

    # EDIT B2 pre-scan: build a map of aliases that are explicitly bound to a
    # specific table in this SQL fragment (overrides TABLE_ALIASES defaults).
    # E.g. if the SQL says "FROM eval_runs r", then r->eval_runs and the
    # TABLE_ALIASES r->routing_events default must NOT be injected.
    _explicit_bind_re = re.compile(
        r"\b(?:FROM|JOIN)\s+(\w+)\s+(?:AS\s+)?(\w+)\b",
        re.IGNORECASE,
    )
    _fragment_explicit_bindings: dict[str, str] = {}
    for _em in _explicit_bind_re.finditer(sql):
        _tbl = _em.group(1).lower()
        _alias = _em.group(2).lower()
        if _alias in TABLE_ALIASES and _tbl in known_tables:
            _fragment_explicit_bindings[_alias] = _tbl

    for m in select_re.finditer(sql):
        select_list = m.group(1)
        # EDIT C: guard against .*? DOTALL over-span past an intermediate FROM
        # (e.g. an f-string "FROM {child}" placeholder); a well-formed SELECT
        # list never contains a FROM keyword.
        if re.search(r'\bFROM\b', select_list, re.IGNORECASE):
            continue
        primary_table = m.group(2).lower()
        explicit_alias = m.group(3)
        # EDIT B1: null explicit_alias if it captured a SQL keyword
        # (e.g. "FROM eval_runs GROUP BY ..." captures "GROUP" as alias)
        if explicit_alias and explicit_alias.upper() in SQL_KEYWORDS:
            explicit_alias = None
        primary_alias = (explicit_alias or primary_table).lower()

        if primary_table not in known_tables:
            continue

        # Build alias → table map for this statement context
        alias_map: dict[str, str] = {
            primary_alias: primary_table,
            primary_table: primary_table,
        }
        # Apply well-known aliases — EDIT B2: skip any alias explicitly bound
        # to a different table in this SQL fragment (prevents r->routing_events
        # from being injected when the fragment uses r as eval_runs's alias).
        for alias, tbl in TABLE_ALIASES.items():
            if tbl in known_tables:
                if (alias in _fragment_explicit_bindings
                        and _fragment_explicit_bindings[alias] != tbl):
                    continue
                alias_map.setdefault(alias, tbl)
        # Parse JOINs and WHERE column refs in a 600-char context window.
        # EDIT A: clip at the next statement boundary (semicolon or next FROM
        # keyword) after the current match so WHERE/column refs from adjacent
        # statements cannot bleed into this statement's primary_table.
        context = sql[m.start() : min(m.start() + 600, len(sql))]
        _match_end_ctx = m.end() - m.start()
        _after_match = context[_match_end_ctx:]
        _semi = _after_match.find(';')
        _next_from = re.search(r'\bFROM\b', _after_match, re.IGNORECASE)
        _clip = min(
            _semi if _semi != -1 else len(_after_match),
            _next_from.start() if _next_from else len(_after_match),
        )
        context = context[:_match_end_ctx + _clip]
        # The 600-char window (above) can bisect a column name at its boundary —
        # e.g. a truncated "s.project" leaves "...WHERE s.proj", which the alias.col
        # regex below would mis-capture as a phantom column ("sessions.proj"). Drop
        # any trailing partial word token so truncation never invents a column.
        # Safe given the checker's "over-capture is_used" bias: a real column at the
        # exact clip edge is captured by its other references; the 600-char window is
        # heuristic, not authoritative.
        context = re.sub(r"\w+$", "", context)
        for jm in join_re.finditer(context):
            jt = jm.group(1).lower()
            ja = (jm.group(2) or jt).lower()
            if jt in known_tables:
                alias_map[ja] = jt
                alias_map[jt] = jt

        # 1. SELECT list: alias.col and bare column names
        for tok in re.split(r",", select_list):
            tok = tok.strip()
            tok = re.sub(r"\s+AS\s+\w+\s*$", "", tok, flags=re.IGNORECASE).strip()
            # alias.col form (definitive attribution)
            for (alias_or_tbl, col) in re.findall(r"\b(\w+)\.(\w+)\b", tok):
                resolved = alias_map.get(alias_or_tbl.lower())
                col = col.lower()
                if (resolved and _COL_RE.match(col)
                        and col.upper() not in SQL_KEYWORDS
                        and col not in NON_COLUMN_IDENTIFIERS):
                    readers.setdefault(resolved, set()).add(col)
            # Bare column name → attribute to primary table
            bare = re.match(r"^\s*(\w+)\s*$", tok)
            if bare:
                col = bare.group(1).lower()
                if (_COL_RE.match(col) and col.upper() not in SQL_KEYWORDS
                        and col != "*" and col not in NON_COLUMN_IDENTIFIERS):
                    readers.setdefault(primary_table, set()).add(col)

        # 2. Alias.col scan limited to SQL keywords context — captures
        # WHERE ar.col, ON s.id = ar.session_id, ORDER BY ar.col, etc.
        # Restricted to patterns following SQL keywords to avoid picking up
        # Python variable access (e.g. conn.execute, args.subcommand).
        sql_ctx_re = re.compile(
            r"\b(?:WHERE|AND|OR|ON|HAVING|BY|SET)\s+"
            r"(?:\w+\s+(?:AND|OR)\s+)*"  # optional chained conditions
            r"(\w+)\.(\w+)\b",
            re.IGNORECASE,
        )
        for sm in sql_ctx_re.finditer(context):
            alias_or_tbl = sm.group(1).lower()
            col = sm.group(2).lower()
            resolved = alias_map.get(alias_or_tbl)
            if (resolved and _COL_RE.match(col)
                    and col.upper() not in SQL_KEYWORDS
                    and col not in NON_COLUMN_IDENTIFIERS):
                readers.setdefault(resolved, set()).add(col)

        # 3. Bare WHERE/AND/OR column references (for single-table queries)
        # e.g. WHERE deleted_at IS NOT NULL → deleted_at on primary_table
        # No re.IGNORECASE: require uppercase SQL keywords to avoid matching
        # English prose like "rows where it is NULL" in Python comments/descriptions.
        where_col_re = re.compile(
            r"\b(?:WHERE|AND|OR|HAVING)\s+(\w+)\s+"
            r"(?:IS\b|=|!=|<>|<|>|<=|>=|LIKE\b|IN\s*\()",
        )
        for wm in where_col_re.finditer(context):
            col = wm.group(1).lower()
            if (_COL_RE.match(col) and col.upper() not in SQL_KEYWORDS
                    and col not in NON_COLUMN_IDENTIFIERS):
                readers.setdefault(primary_table, set()).add(col)

    return writers, readers


# ─── Source Extraction: CAST scripts ──────────────────────────────────────────

def scan_cast_scripts(
    scripts_dir: Path,
    bin_cast: Path,
    known_tables: set[str],
) -> tuple[dict[str, dict[str, set[str]]], dict[str, dict[str, set[str]]]]:
    """Scan CAST scripts for SQL column writes and reads.

    Returns (writers, readers): {table: {col: {file_labels}}}.
    Biased toward false-positive "is used"; use fill_rate from --db for
    higher-confidence dead-column claims.
    """
    writers: dict[str, dict[str, set[str]]] = {}
    readers: dict[str, dict[str, set[str]]] = {}

    paths: list[Path] = []
    if scripts_dir.exists():
        paths.extend(scripts_dir.glob("*.sh"))
        paths.extend(scripts_dir.glob("*.py"))
    if bin_cast.exists():
        paths.append(bin_cast)

    for fpath in paths:
        try:
            content = fpath.read_text(errors="replace")
        except OSError:
            continue
        label = str(fpath.relative_to(REPO_ROOT))
        for frag in _extract_sql_fragments(content):
            w, r = _parse_sql_ops(frag, known_tables)
            for table, cols in w.items():
                for col in cols:
                    writers.setdefault(table, {}).setdefault(col, set()).add(label)
            for table, cols in r.items():
                for col in cols:
                    readers.setdefault(table, {}).setdefault(col, set()).add(label)

    return writers, readers


# ─── Source Extraction: ALLOWED_TABLES + db_write call sites ─────────────────

def extract_allowed_tables(cast_db_path: Path) -> set[str]:
    """Extract ALLOWED_TABLES from cast_db.py without importing it.

    Parses the set literal `ALLOWED_TABLES = { 'table', ... }` using a regex.
    This is a static read — the module is NOT imported (avoids import side-effects
    and path issues from running inside a different working directory).

    Returns the set of table name strings, or empty set if the file is missing
    or the pattern is not found.
    """
    try:
        content = cast_db_path.read_text(errors="replace")
    except OSError as e:
        print(f"[WARN] Cannot read {cast_db_path}: {e}", file=sys.stderr)
        return set()

    m = re.search(r"ALLOWED_TABLES\s*=\s*\{([^}]+)\}", content, re.DOTALL)
    if not m:
        print(
            f"[WARN] ALLOWED_TABLES not found in {cast_db_path}",
            file=sys.stderr,
        )
        return set()

    return {s for s in re.findall(r"['\"](\w+)['\"]", m.group(1))}


def scan_db_write_calls(
    scripts_dir: Path,
    bin_cast: Path,
    allowed_tables: set[str],
    known_tables: set[str],
) -> tuple[set[str], dict[str, dict[str, set[str]]]]:
    """Scan CAST scripts for db_write() call sites.

    Detects two patterns:
      1. Literal dict:  db_write('table', {'col1': v, 'col2': v})
         → extracts table + columns (column-level precision)
      2. Non-literal:   db_write('table', payload) / cast_db.db_write('table', row)
         → extracts table only (table-granularity evidence)

    Also pre-seeds `dynamic_tables` from `allowed_tables` — any table in
    ALLOWED_TABLES is a dynamic-writer target by definition, even if no
    literal call site was found in the scanned files (e.g. the call is inside
    a shell heredoc that the scanner misses).

    Args:
        scripts_dir:    directory of CAST .py/.sh scripts to scan
        bin_cast:       path to bin/cast (scanned if it exists)
        allowed_tables: tables from ALLOWED_TABLES in cast_db.py
        known_tables:   tables declared in init/migrations (scoped to avoid
                        registering references to unrelated table names)

    Returns:
        dynamic_tables:      set of table names that are db_write targets
        dynamic_col_writers: {table: {col: {file_labels}}} for literal-dict calls
    """
    # Seed from ALLOWED_TABLES — these are dynamic-writer targets regardless
    # of whether a literal call site is found.
    dynamic_tables: set[str] = set(allowed_tables & known_tables)
    dynamic_col_writers: dict[str, dict[str, set[str]]] = {}

    paths: list[Path] = []
    if scripts_dir.exists():
        paths.extend(scripts_dir.glob("*.sh"))
        paths.extend(scripts_dir.glob("*.py"))
    if bin_cast.exists():
        paths.append(bin_cast)

    # Matches:  db_write('TABLE', ...  or  cast_db.db_write("TABLE", ...
    call_re = re.compile(
        r"(?:cast_db\.)?db_write\s*\(\s*['\"](\w+)['\"]\s*,\s*",
    )
    # Dict key pattern:  'colname':  or  "colname":
    dict_key_re = re.compile(r"""['"]([\w]+)['"]\s*:""")

    for fpath in paths:
        try:
            content = fpath.read_text(errors="replace")
        except OSError:
            continue

        # Relative label for provenance (falls back to full path if outside REPO_ROOT)
        try:
            label = str(fpath.relative_to(REPO_ROOT))
        except ValueError:
            label = str(fpath)

        for m in call_re.finditer(content):
            table = m.group(1).lower()
            if table not in known_tables:
                continue

            # Register as a dynamic-writer table (call-site evidence)
            dynamic_tables.add(table)

            # Check whether the second argument is a literal dict `{ ... }`
            rest = content[m.end():m.end() + 600]
            rest_stripped = rest.lstrip()
            if not rest_stripped.startswith("{"):
                continue  # non-literal payload — table registered above, done

            # Walk forward to find the matching closing brace
            depth = 0
            dict_end = 0
            for i, ch in enumerate(rest_stripped):
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        dict_end = i + 1
                        break

            if dict_end == 0:
                continue  # unmatched brace — skip

            dict_body = rest_stripped[:dict_end]
            for km in dict_key_re.finditer(dict_body):
                col = km.group(1).lower()
                if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
                    (
                        dynamic_col_writers
                        .setdefault(table, {})
                        .setdefault(col, set())
                        .add(label)
                    )

    return dynamic_tables, dynamic_col_writers


# ─── Source Extraction: cast-desktop ──────────────────────────────────────────

def scan_desktop(
    desktop_path: Path,
    known_tables: set[str],
) -> tuple[dict[str, dict[str, set[str]]], bool]:
    """Scan cast-desktop server SQL for column reads.

    Returns (readers, desktop_found).
    If desktop_path is absent, returns ({}, False).
    NEVER treats "absent" as "no reads" — the caller must mark all
    columns UNCHECKED when desktop_found is False.
    """
    routes_dir = desktop_path / "server" / "routes"
    parsers_dir = desktop_path / "server" / "parsers"

    if not routes_dir.exists():
        return {}, False

    readers: dict[str, dict[str, set[str]]] = {}
    scan_dirs = [routes_dir]
    if parsers_dir.exists():
        scan_dirs.append(parsers_dir)

    for scan_dir in scan_dirs:
        for fpath in scan_dir.glob("*.ts"):
            try:
                content = fpath.read_text(errors="replace")
            except OSError:
                continue
            label = f"cast-desktop/{fpath.relative_to(desktop_path)}"
            for frag in _extract_sql_fragments(content):
                _, r = _parse_sql_ops(frag, known_tables)
                for table, cols in r.items():
                    for col in cols:
                        readers.setdefault(table, {}).setdefault(col, set()).add(label)

    return readers, True


# ─── DB Fill Rates (optional enrichment) ──────────────────────────────────────

def get_fill_rates(
    db_path: Path,
) -> tuple[dict[tuple[str, str], Optional[float]], bool]:
    """Get non-NULL fill rate per (table, column). Read-only access.

    Returns ({(table, col): float}, db_found).
    Empty string values count as NULL (most CAST writes use empty-or-NULL).
    """
    fill_rates: dict[tuple[str, str], Optional[float]] = {}
    if not db_path.exists():
        return fill_rates, False

    try:
        uri = f"file:{db_path}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=5)
    except sqlite3.Error as e:
        print(f"[WARN] Cannot open DB {db_path}: {e}", file=sys.stderr)
        return fill_rates, False

    try:
        tables = [
            r[0]
            for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        ]
        for table in tables:
            if not _SCHEMA_IDENT_RE.match(table):
                continue
            try:
                cols = [
                    r[1] for r in conn.execute(
                        f"PRAGMA table_info([{table}])"
                    ).fetchall()
                ]
                total = conn.execute(f"SELECT COUNT(*) FROM [{table}]").fetchone()[0]
                if total == 0:
                    for col in cols:
                        fill_rates[(table, col)] = 0.0
                    continue
                for col in cols:
                    if not _SCHEMA_IDENT_RE.match(col):
                        continue
                    non_null = conn.execute(
                        f"SELECT COUNT(*) FROM [{table}]"
                        f" WHERE [{col}] IS NOT NULL AND [{col}] != ''"
                    ).fetchone()[0]
                    fill_rates[(table, col)] = round(non_null / total, 3)
            except sqlite3.Error:
                continue
    finally:
        conn.close()

    return fill_rates, True


# ─── Contract Assembly ────────────────────────────────────────────────────────

def build_contracts(
    init_schema: dict[str, set[str]],
    migration_added: dict[str, set[str]],
    migration_dropped: dict[str, set[str]],
    script_writers: dict[str, dict[str, set[str]]],
    script_readers: dict[str, dict[str, set[str]]],
    desktop_readers: dict[str, dict[str, set[str]]],
    desktop_found: bool,
    fill_rates: dict[tuple[str, str], Optional[float]],
    db_found: bool,
    dynamic_tables: set[str] | None = None,
    dynamic_col_writers: dict[str, dict[str, set[str]]] | None = None,
    auto_populated_cols: dict[str, set[str]] | None = None,
    directives: dict[str, dict] | None = None,
) -> list[ColumnContract]:
    """Assemble ColumnContract objects for all currently-relevant columns.

    A column is 'currently relevant' if it appears in at least one of:
    init_schema, migration net-adds (excluding dropped), script references,
    or desktop references. Pure migration-history drops (already removed from
    init and unreferenced by any script/desktop) are excluded.

    dynamic_tables and dynamic_col_writers come from scan_db_write_calls().
    When a table is in dynamic_tables, all its declared columns are marked
    dynamic_writer_table=True so they are never classified SAFE-DROP-CANDIDATE.
    When a column appears in dynamic_col_writers, it also gets
    dynamic_writer_cols set for column-level proven evidence.
    """
    _dynamic_tables = dynamic_tables or set()
    _dynamic_col_writers = dynamic_col_writers or {}

    all_tables: set[str] = set()
    for d in (init_schema, migration_added, script_writers, script_readers, desktop_readers):
        all_tables.update(d.keys())

    contracts: list[ColumnContract] = []
    for table in sorted(all_tables):
        all_cols: set[str] = set()
        # Declared in init
        all_cols.update(init_schema.get(table, set()))
        # Migration net-adds (only cols that weren't subsequently dropped)
        for col in migration_added.get(table, set()):
            if col not in migration_dropped.get(table, set()):
                all_cols.add(col)
        # Script references (may surface undeclared columns as CONTRADICTION)
        all_cols.update(script_writers.get(table, {}).keys())
        all_cols.update(script_readers.get(table, {}).keys())
        # Desktop references
        all_cols.update(desktop_readers.get(table, {}).keys())

        # Also include init-declared cols that migration dropped (for CONTRADICTION)
        for col in migration_dropped.get(table, set()):
            if col in init_schema.get(table, set()):
                all_cols.add(col)

        for col in sorted(all_cols):
            # Determine dynamic-writer fields for this (table, col) pair.
            # dynamic_writer_table: True if the table is a db_write target.
            # dynamic_writer_cols: list of columns proven via literal dict args.
            is_dynamic_table = table in _dynamic_tables
            proven_cols = list(
                _dynamic_col_writers.get(table, {}).get(col, set())
            )
            contracts.append(
                ColumnContract(
                    table=table,
                    column=col,
                    declared_in_init=col in init_schema.get(table, set()),
                    migration_added=col in migration_added.get(table, set()),
                    migration_dropped=col in migration_dropped.get(table, set()),
                    script_writers=sorted(
                        script_writers.get(table, {}).get(col, set())
                    ),
                    script_readers=sorted(
                        script_readers.get(table, {}).get(col, set())
                    ),
                    desktop_readers=sorted(
                        desktop_readers.get(table, {}).get(col, set())
                    ),
                    desktop_checked=desktop_found,
                    fill_rate=fill_rates.get((table, col)),
                    db_checked=db_found,
                    dynamic_writer_table=is_dynamic_table,
                    dynamic_writer_cols=[col] if proven_cols else [],
                    auto_populated=col in (auto_populated_cols or {}).get(table, set()),
                    provenance=((directives or {}).get(table) or {}).get("kind"),
                )
            )

    return contracts


# ─── Output ───────────────────────────────────────────────────────────────────

_CLASS_ORDER = {
    "CONTRADICTION": 0,
    "FIX-WRITER": 1,
    "SAFE-DROP-CANDIDATE": 2,
    "DESKTOP-COUPLED": 3,
    "KEEP": 4,
    "EXTERNAL-WRITER": 5,
    "DECLARED-RESERVED": 6,
}


def format_table_output(contracts: list[ColumnContract], desktop_found: bool) -> str:
    lines: list[str] = []
    if not desktop_found:
        lines.append(
            "[WARN] cast-desktop not found — desktop verdicts are UNCHECKED."
        )
        lines.append("")

    by_table: dict[str, list[ColumnContract]] = {}
    for c in contracts:
        by_table.setdefault(c.table, []).append(c)

    for table in sorted(by_table):
        rows = sorted(
            by_table[table],
            key=lambda c: (_CLASS_ORDER.get(c.classification, 5), c.column),
        )
        lines.append(f"── {table} {'─' * max(0, 60 - len(table))}")
        for c in rows:
            fill = ""
            if c.db_checked and c.fill_rate is not None:
                fill = f" [fill:{c.fill_rate:.0%}]"
            elif not c.db_checked:
                fill = " [fill:unchecked]"
            desk = " [desktop:UNCHECKED]" if not c.desktop_checked else ""
            w_files = ",".join(
                Path(f).name for f in sorted(c.script_writers)[:2]
            )
            r_files = ",".join(
                Path(f).name for f in sorted(c.script_readers)[:2]
            )
            w_str = f" w:{w_files}" if w_files else ""
            r_str = f" r:{r_files}" if r_files else ""
            lines.append(
                f"  {c.column:<35} {c.classification:<22}{fill}{desk}{w_str}{r_str}"
            )
        lines.append("")

    return "\n".join(lines)


def _get_git_sha() -> str:
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, cwd=str(REPO_ROOT),
        )
        return r.stdout.strip() if r.returncode == 0 else "unknown"
    except OSError:
        return "unknown"


def format_json_output(contracts: list[ColumnContract], desktop_found: bool) -> str:
    tables: dict[str, list[dict]] = {}
    for c in contracts:
        tables.setdefault(c.table, []).append(c.to_dict())
    check_mode = (
        "full (contradictions + safe-drop candidates)"
        if desktop_found
        else "contradictions-only (desktop: UNCHECKED — safe-drop ratchet skipped)"
    )
    manifest = {
        "schema_version": "1.0",
        "generated_from": _get_git_sha(),
        "desktop_checked": desktop_found,
        "check_mode": check_mode,
        "tables": tables,
    }
    return json.dumps(manifest, indent=2)


# ─── Baseline / Ratchet ───────────────────────────────────────────────────────

def _load_baseline(baseline_path: Path) -> dict:
    if not baseline_path.exists():
        return {"contradictions": [], "safe_drop_candidates": []}
    try:
        return json.loads(baseline_path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        print(f"[WARN] Cannot read baseline {baseline_path}: {e}", file=sys.stderr)
        return {"contradictions": [], "safe_drop_candidates": []}


def check_against_baseline(
    contracts: list[ColumnContract],
    baseline_path: Path,
    desktop_found: bool,
) -> tuple[list[dict], list[dict], str]:
    """Compare current state against the committed ratchet baseline.

    When desktop_found is False (UNCHECKED), safe-drop-candidate ratcheting
    is skipped entirely. Columns that would be DESKTOP-COUPLED with a real
    desktop degrade to SAFE-DROP-CANDIDATE when desktop is absent; ratcheting
    those as "new" would produce false CI failures. Contradictions are always
    checked regardless of desktop availability.

    Returns (new_contradictions, new_safe_drops, check_mode) where check_mode
    is a human-readable string stating the active ratchet scope.
    Caller should exit 1 if new_contradictions or new_safe_drops are non-empty.
    """
    if desktop_found:
        check_mode = "full (contradictions + safe-drop candidates)"
    else:
        check_mode = (
            "contradictions-only "
            "(desktop: UNCHECKED — safe-drop ratchet skipped)"
        )

    baseline = _load_baseline(baseline_path)
    known_contras = {
        (e["table"], e["column"]) for e in baseline.get("contradictions", [])
    }
    known_drops = {
        (e["table"], e["column"]) for e in baseline.get("safe_drop_candidates", [])
    }

    new_contras: list[dict] = []
    for c in contracts:
        if c.classification == "CONTRADICTION" and (c.table, c.column) not in known_contras:
            new_contras.append(c.to_dict())

    # Safe-drop ratcheting requires desktop evidence. Without it, skip entirely.
    new_drops: list[dict] = []
    if desktop_found:
        for c in contracts:
            if (
                c.classification == "SAFE-DROP-CANDIDATE"
                and (c.table, c.column) not in known_drops
            ):
                new_drops.append(c.to_dict())

    return new_contras, new_drops, check_mode


def write_baseline(contracts: list[ColumnContract], baseline_path: Path) -> None:
    """Write (or overwrite) the ratchet baseline from the current contract state."""
    contradictions = [
        {"table": c.table, "column": c.column, "classification": c.classification}
        for c in contracts if c.classification == "CONTRADICTION"
    ]
    safe_drops = [
        {"table": c.table, "column": c.column, "classification": c.classification}
        for c in contracts if c.classification == "SAFE-DROP-CANDIDATE"
    ]
    baseline = {
        "schema_version": "1.0",
        "generated_from": _get_git_sha(),
        "note": (
            "Ratchet baseline for cast-db-contract --check. "
            "Exit 1 only on NEW entries absent from this file. "
            "Regenerate with: python3 scripts/cast-db-contract.py --update-baseline"
        ),
        "contradictions": sorted(
            contradictions, key=lambda e: (e["table"], e["column"])
        ),
        "safe_drop_candidates": sorted(
            safe_drops, key=lambda e: (e["table"], e["column"])
        ),
    }
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    baseline_path.write_text(json.dumps(baseline, indent=2) + "\n")
    print(f"[INFO] Baseline written to {baseline_path}", file=sys.stderr)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="cast-db-contract: schema/DB-contract reconciliation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--json", dest="emit_json", action="store_true",
        help="Emit full machine manifest as JSON",
    )
    parser.add_argument(
        "--db", default=str(DEFAULT_DB),
        help=f"cast.db path (read-only). Default: $CAST_DB_PATH or {DEFAULT_DB}",
    )
    parser.add_argument(
        "--desktop-path", default=str(DEFAULT_DESKTOP_PATH),
        help=f"cast-desktop repo root. Default: {DEFAULT_DESKTOP_PATH}",
    )
    parser.add_argument(
        "--check", action="store_true",
        help=(
            "Ratchet check: exit 1 if CONTRADICTIONS or SAFE-DROP-CANDIDATEs "
            "are found that are absent from the baseline."
        ),
    )
    parser.add_argument(
        "--update-baseline", action="store_true",
        help="Write current contract state as the new ratchet baseline.",
    )
    parser.add_argument(
        "--baseline", default=str(DEFAULT_BASELINE),
        help=f"Baseline file path. Default: {DEFAULT_BASELINE}",
    )
    args = parser.parse_args()

    desktop_path = Path(args.desktop_path)
    db_path = Path(args.db)
    baseline_path = Path(args.baseline)

    # ── 1. Extract sources ──────────────────────────────────────────────────
    init_schema = parse_init_schema(INIT_SCRIPT)
    auto_populated_cols = parse_auto_populated(INIT_SCRIPT)
    directives = parse_contract_directives(INIT_SCRIPT)
    migration_added, migration_dropped = parse_migrations(MIGRATIONS_DIR)

    known_tables: set[str] = set(init_schema.keys())
    known_tables.update(migration_added.keys())
    known_tables.update(migration_dropped.keys())

    script_writers, script_readers = scan_cast_scripts(
        SCRIPT_DIR, REPO_ROOT / "bin" / "cast", known_tables
    )

    # ── db_write() dynamic writer detection ────────────────────────────────
    allowed_tables = extract_allowed_tables(CAST_DB_PY)
    dynamic_tables, dynamic_col_writers = scan_db_write_calls(
        SCRIPT_DIR,
        REPO_ROOT / "bin" / "cast",
        allowed_tables,
        known_tables,
    )

    desktop_readers, desktop_found = scan_desktop(desktop_path, known_tables)

    if not desktop_found:
        print(
            f"[WARN] cast-desktop not found at {desktop_path} — "
            "desktop columns are UNCHECKED. Override with --desktop-path.",
            file=sys.stderr,
        )

    fill_rates, db_found = get_fill_rates(db_path)
    if not db_found:
        print(
            f"[INFO] cast.db not found at {db_path} — fill_rate will be null.",
            file=sys.stderr,
        )

    # ── 2. Assemble contracts ───────────────────────────────────────────────
    contracts = build_contracts(
        init_schema=init_schema,
        migration_added=migration_added,
        migration_dropped=migration_dropped,
        script_writers=script_writers,
        script_readers=script_readers,
        desktop_readers=desktop_readers,
        desktop_found=desktop_found,
        fill_rates=fill_rates,
        db_found=db_found,
        dynamic_tables=dynamic_tables,
        dynamic_col_writers=dynamic_col_writers,
        auto_populated_cols=auto_populated_cols,
        directives=directives,
    )

    # ── 3. Output ───────────────────────────────────────────────────────────
    if args.emit_json:
        print(format_json_output(contracts, desktop_found))
    else:
        print(format_table_output(contracts, desktop_found))

    # ── 4. Write baseline ───────────────────────────────────────────────────
    if args.update_baseline:
        write_baseline(contracts, baseline_path)

    # ── 5. Ratchet check ────────────────────────────────────────────────────
    if args.check:
        new_contras, new_drops, check_mode = check_against_baseline(
            contracts, baseline_path, desktop_found
        )
        print(f"[CHECK] mode: {check_mode}", file=sys.stderr)
        if new_contras or new_drops:
            print("[FAIL] New entries not in baseline:", file=sys.stderr)
            for e in new_contras:
                print(f"  CONTRADICTION      : {e['table']}.{e['column']}", file=sys.stderr)
            for e in new_drops:
                print(
                    f"  SAFE-DROP-CANDIDATE: {e['table']}.{e['column']}",
                    file=sys.stderr,
                )
            print(
                "  Run --update-baseline to accept these as the new baseline.",
                file=sys.stderr,
            )
            return 1
        print("[PASS] No new schema-contract violations vs baseline.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)
    except Exception as exc:
        # Always emit valid JSON on unhandled error
        print(json.dumps({"error": str(exc), "type": type(exc).__name__}))
        sys.exit(1)
