#!/usr/bin/env python3
"""cast-ask-index.py — populate record_fts from cast.db text sources.

Usage:
    cast-ask-index.py [--rebuild] [--kind <k>] [--db <path>]

Options:
    --rebuild       Delete all record_fts rows then full-reindex (leaves record_embed untouched)
    --kind <k>      Only index this kind (agent_run, incident, dispatch, memory, plan)
    --db <path>     Override CAST_DB_PATH for this run

Exit codes: 0 = success, 1 = error
Per-source failures are logged to stderr; one bad source does not abort the rest.
"""

import argparse
import os
import sys
from typing import Any, Dict, List, Optional

# --- DB import (match existing scripts pattern) ---
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cast_db  # type: ignore

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MAX_BODY = 4_000  # chars — bounds large rows; Unit 3 transcripts will rely on this


# ---------------------------------------------------------------------------
# SOURCES config
# Each entry drives the incremental-index logic for one kind.
# Unit 3 can append additional kinds (journal, transcript) to this list.
# ---------------------------------------------------------------------------

SOURCES: List[Dict[str, Any]] = [
    {
        "kind": "agent_run",
        "table": "agent_runs",
        "ref_id_col": "id",
        "ts_col": "COALESCE(ended_at, started_at)",
        "title_expr": "agent || ' · ' || COALESCE(status, '')",
        "body_parts": ["response"],
    },
    {
        "kind": "incident",
        "table": "incidents",
        "ref_id_col": "id",
        "ts_col": "occurred_at",
        "title_expr": "substr(problem_summary, 1, 80)",
        "body_parts": ["problem_summary", "fix_summary"],
    },
    {
        "kind": "dispatch",
        "table": "dispatch_decisions",
        "ref_id_col": "id",
        "ts_col": "created_at",
        "title_expr": "chosen_agent || ' · ' || outcome",
        "body_parts": ["prompt_snippet", "outcome", "chosen_agent"],
    },
    {
        "kind": "memory",
        "table": "agent_memories",
        "ref_id_col": "id",
        "ts_col": "COALESCE(updated_at, created_at)",
        "title_expr": "name",
        "body_parts": ["name", "description", "content"],
    },
    {
        "kind": "plan",
        "table": "plan_sessions",
        "ref_id_col": "id",
        "ts_col": "started_at",
        "title_expr": "plan_file",  # basename extracted in Python
        "body_parts": ["plan_file"],
    },
]


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


def _row_to_dict(row: Any) -> Dict[str, Any]:
    """Convert sqlite3.Row (or dict) to plain dict."""
    if isinstance(row, dict):
        return row
    # sqlite3.Row supports keys()
    if hasattr(row, "keys"):
        return dict(row)
    # Fallback: shouldn't happen with cast_db
    return {}


def _concat_body(row: Dict[str, Any], parts: List[str]) -> str:
    """Space-join non-NULL, non-empty body parts; truncate to MAX_BODY."""
    pieces: List[str] = []
    for p in parts:
        val = row.get(p)
        if val is not None and str(val).strip():
            pieces.append(str(val))
    return " ".join(pieces)[:MAX_BODY]


def _get_high_water(kind: str) -> Optional[str]:
    """Return max ts from record_fts for this kind, or None if no rows."""
    rows = cast_db.db_query(
        "SELECT max(ts) AS hw FROM record_fts WHERE kind = ?", (kind,)
    )
    if rows:
        row = _row_to_dict(rows[0])
        hw = row.get("hw")
        return hw if hw else None
    return None


def _upsert_row(kind: str, ref_id: str, ts: str, title: str, body: str) -> None:
    """Delete-then-insert to keep record_fts deduplicated on (kind, ref_id)."""
    cast_db.db_execute(
        "DELETE FROM record_fts WHERE kind = ? AND ref_id = ?", (kind, ref_id)
    )
    cast_db.db_execute(
        "INSERT INTO record_fts(kind, ref_id, ts, title, body) VALUES (?, ?, ?, ?, ?)",
        (kind, ref_id, ts, title, body),
    )


def _index_source(src: Dict[str, Any], rebuild: bool) -> int:
    """Index one source; return count of rows inserted."""
    kind = src["kind"]
    table = src["table"]
    ref_id_col = src["ref_id_col"]
    ts_col = src["ts_col"]
    title_expr = src["title_expr"]
    body_parts: List[str] = src["body_parts"]

    high_water: Optional[str] = None
    if not rebuild:
        high_water = _get_high_water(kind)

    # SQL identifiers (table, ref_id_col, body columns) are validated to honor cast_db's
    # own guard, even though SOURCES is a hardcoded constant today. ts_col and title_expr
    # are TRUSTED SQL EXPRESSION LITERALS (e.g. "COALESCE(ended_at, started_at)") — they
    # must remain hardcoded in SOURCES; never source them from config files or user input.
    cast_db._validate_identifier(table)
    cast_db._validate_identifier(ref_id_col)
    for _col in body_parts:
        cast_db._validate_identifier(_col)

    # Build SELECT — ts/title evaluated in SQL; body parts capped at the SQL level via
    # SUBSTR so large rows (e.g. agent_runs.response) are never fully loaded into memory.
    body_selects = ", ".join(
        f"CAST(SUBSTR({col}, 1, {MAX_BODY + 1}) AS TEXT) AS {col}" for col in body_parts
    )
    select_sql = (
        f"SELECT CAST({ref_id_col} AS TEXT) AS ref_id, "
        f"({ts_col}) AS ts, "
        f"({title_expr}) AS title, "
        f"{body_selects} "
        f"FROM {table}"
    )

    params: tuple = ()
    if high_water:
        # >= (not >) so rows sharing the boundary timestamp are never skipped; the
        # delete-then-insert upsert keeps this idempotent (boundary rows re-index without
        # duplicating). Empty high_water is treated as None above → first run indexes all.
        select_sql += f" WHERE ({ts_col}) >= ?"
        params = (high_water,)

    rows = cast_db.db_query(select_sql, params)
    count = 0
    for raw_row in rows:
        row = _row_to_dict(raw_row)

        ref_id = str(row.get("ref_id") or "")
        if not ref_id.strip():
            continue  # skip rows with no ref_id — cannot dedup on (kind, ref_id)
        ts_val = str(row.get("ts") or "")
        title_val = str(row.get("title") or "")

        # plan kind: extract basename from plan_file path
        if kind == "plan" and title_val:
            title_val = os.path.basename(title_val)

        body_val = _concat_body(row, body_parts)

        if not body_val.strip():
            continue  # skip rows whose body is entirely NULL/empty after concat

        _upsert_row(kind, ref_id, ts_val, title_val, body_val)
        count += 1

    return count


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Populate record_fts from cast.db sources."
    )
    parser.add_argument(
        "--rebuild", action="store_true",
        help="Full reindex: delete all record_fts rows first (leaves record_embed untouched)",
    )
    parser.add_argument(
        "--kind", metavar="K",
        help="Only index this kind (agent_run, incident, dispatch, memory, plan)",
    )
    parser.add_argument(
        "--db", metavar="PATH",
        help="Override CAST_DB_PATH for this run",
    )
    args = parser.parse_args()

    # Apply --db override before cast_db is used (CAST_DB_PATH read lazily)
    if args.db:
        os.environ["CAST_DB_PATH"] = args.db

    sources = SOURCES
    if args.kind:
        sources = [s for s in SOURCES if s["kind"] == args.kind]
        if not sources:
            valid = [s["kind"] for s in SOURCES]
            print(f"Unknown kind: {args.kind!r}. Valid: {valid}", file=sys.stderr)
            return 1

    if args.rebuild:
        ok = cast_db.db_execute("DELETE FROM record_fts", ())
        if not ok:
            print("Failed to clear record_fts for rebuild", file=sys.stderr)
            return 1
        print("record_fts cleared for full rebuild")

    exit_code = 0
    for src in sources:
        try:
            n = _index_source(src, rebuild=args.rebuild)
            print(f"indexed {n} {src['kind']} rows")
        except Exception as exc:
            print(f"ERROR indexing {src['kind']}: {exc}", file=sys.stderr)
            exit_code = 1  # flag error but continue remaining sources

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
