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

Desktop-absent policy: if cast-desktop is not found at the configured path,
all desktop verdicts are UNCHECKED. "Unreachable" is never treated as
"no reads" (CAST honest-degradation principle).

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
DEFAULT_DESKTOP_PATH = Path.home() / "Projects" / "personal" / "cast-desktop"
DEFAULT_BASELINE = REPO_ROOT / ".github" / "db-contract-baseline.json"
DEFAULT_DB = Path(os.environ.get("CAST_DB_PATH", str(Path.home() / ".claude" / "cast.db")))

# SQL keywords: excluded when extracting bare column names from SQL text
# Minimum identifier length and pattern for valid SQL column names.
# Requires: starts with letter or underscore, at least 2 characters.
# This filters out numeric literals (1, 0), single-letter variables (c, r, t),
# and other parsing artifacts while keeping all valid CAST column names.
_COL_RE = re.compile(r"^[a-zA-Z]\w+$")

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

    @property
    def classification(self) -> str:
        """Classify column based on available evidence.

        Priority order (highest wins):
          1. CONTRADICTION — init-declared but migration-dropped, OR
             referenced in scripts but never declared anywhere
          2. DESKTOP-COUPLED — desktop reads it (only when desktop is reachable)
          3. KEEP — at least one CAST script writer found
          4. FIX-WRITER — read by scripts but no writer
          5. SAFE-DROP-CANDIDATE — nothing writes or reads it
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
        # FIX-WRITER: something reads it but nothing writes it
        if self.script_readers and not self.script_writers:
            return "FIX-WRITER"
        # KEEP: at least one writer (column is being collected)
        if self.script_writers:
            return "KEEP"
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
        }


# ─── Source Extraction: init schema ───────────────────────────────────────────

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

    schema: dict[str, set[str]] = {}
    table_re = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(",
        re.IGNORECASE,
    )
    for match in table_re.finditer(content):
        table = match.group(1).lower()
        block = _extract_paren_block(content, match.end())
        cols = _parse_create_table_columns(block)
        schema.setdefault(table, set()).update(cols)

    # Self-healing ALTER TABLE ADD COLUMN in the init also constitutes a declaration
    for m in re.finditer(
        r"ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)",
        content, re.IGNORECASE,
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

        # CREATE TABLE in migrations: track columns
        for match in table_re.finditer(content):
            table = match.group(1).lower()
            block = _extract_paren_block(content, match.end())
            for col in _parse_create_table_columns(block):
                added.setdefault(table, set()).add(col)
                dropped.get(table, set()).discard(col)

        # ADD COLUMN
        for m in add_re.finditer(content):
            table, col = m.group(1).lower(), m.group(2).lower()
            added.setdefault(table, set()).add(col)
            dropped.get(table, set()).discard(col)

        # DROP COLUMN
        for m in drop_re.finditer(content):
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

    for m in select_re.finditer(sql):
        select_list = m.group(1)
        primary_table = m.group(2).lower()
        explicit_alias = m.group(3)
        primary_alias = (explicit_alias or primary_table).lower()

        if primary_table not in known_tables:
            continue

        # Build alias → table map for this statement context
        alias_map: dict[str, str] = {
            primary_alias: primary_table,
            primary_table: primary_table,
        }
        # Apply well-known aliases
        for alias, tbl in TABLE_ALIASES.items():
            if tbl in known_tables:
                alias_map.setdefault(alias, tbl)
        # Parse JOINs and WHERE column refs in a 600-char context window.
        # Larger windows cause cross-contamination from adjacent SQL blocks in
        # large files (e.g. bin/cast), attributing columns to the wrong table.
        context = sql[m.start() : min(m.start() + 600, len(sql))]
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
                if resolved and _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
                    readers.setdefault(resolved, set()).add(col)
            # Bare column name → attribute to primary table
            bare = re.match(r"^\s*(\w+)\s*$", tok)
            if bare:
                col = bare.group(1).lower()
                if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS and col != "*":
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
            if resolved and _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
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
            if _COL_RE.match(col) and col.upper() not in SQL_KEYWORDS:
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
) -> list[ColumnContract]:
    """Assemble ColumnContract objects for all currently-relevant columns.

    A column is 'currently relevant' if it appears in at least one of:
    init_schema, migration net-adds (excluding dropped), script references,
    or desktop references. Pure migration-history drops (already removed from
    init and unreferenced by any script/desktop) are excluded.
    """
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
    manifest = {
        "schema_version": "1.0",
        "generated_from": _get_git_sha(),
        "desktop_checked": desktop_found,
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
) -> tuple[list[dict], list[dict]]:
    """Compare current state against the committed ratchet baseline.

    Returns (new_contradictions, new_safe_drops) — entries present now but
    absent from the baseline. Caller should exit 1 if either list is non-empty.
    """
    baseline = _load_baseline(baseline_path)
    known_contras = {
        (e["table"], e["column"]) for e in baseline.get("contradictions", [])
    }
    known_drops = {
        (e["table"], e["column"]) for e in baseline.get("safe_drop_candidates", [])
    }
    new_contras: list[dict] = []
    new_drops: list[dict] = []
    for c in contracts:
        key = (c.table, c.column)
        if c.classification == "CONTRADICTION" and key not in known_contras:
            new_contras.append(c.to_dict())
        elif c.classification == "SAFE-DROP-CANDIDATE" and key not in known_drops:
            new_drops.append(c.to_dict())
    return new_contras, new_drops


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
    migration_added, migration_dropped = parse_migrations(MIGRATIONS_DIR)

    known_tables: set[str] = set(init_schema.keys())
    known_tables.update(migration_added.keys())
    known_tables.update(migration_dropped.keys())

    script_writers, script_readers = scan_cast_scripts(
        SCRIPT_DIR, REPO_ROOT / "bin" / "cast", known_tables
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
        new_contras, new_drops = check_against_baseline(contracts, baseline_path)
        if new_contras or new_drops:
            print("\n[FAIL] New entries not in baseline:", file=sys.stderr)
            for e in new_contras:
                print(f"  CONTRADICTION    : {e['table']}.{e['column']}", file=sys.stderr)
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
