#!/usr/bin/env python3
"""
cast-db-incidents.py — CLI for querying the CAST incidents table.

Subcommands:
  recent [N]         Show N most recent incidents (default 10). Supports --status flag.
  search <kw>        Case-insensitive search on problem_summary or fix_summary.

Both subcommands accept --json for machine-readable output.
"""
import sys
import os
import json
import argparse
import logging
from pathlib import Path
from typing import Optional

# Add scripts dir to path so cast_db is importable when run directly
sys.path.insert(0, str(Path(__file__).parent))

try:
    from cast_db import db_query
except ImportError as e:
    print(f"(error: cannot import cast_db — {e})", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
LOG_PATH = os.path.expanduser("~/.claude/logs/cast-db-incidents.log")

def _setup_logging() -> None:
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    logging.basicConfig(
        filename=LOG_PATH,
        level=logging.ERROR,
        format="%(asctime)s %(levelname)s %(message)s",
    )

# ---------------------------------------------------------------------------
# DB path
# ---------------------------------------------------------------------------
DB_PATH = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))


def _format_incident(row: dict) -> str:
    """Return a human-readable block for a single incident row."""
    incident_id = (row.get("id") or "")[:8]
    occurred_at = row.get("occurred_at") or ""
    problem = (row.get("problem_summary") or "")[:80]
    status = row.get("resolution_status") or "unknown"
    commit = row.get("related_commit") or ""
    commit_display = commit[:8] if commit else "(none)"

    lines = [
        f"--- {incident_id} ---",
        f"  occurred : {occurred_at}",
        f"  problem  : {problem}",
        f"  status   : {status}",
        f"  commit   : {commit_display}",
    ]
    return "\n".join(lines)


def _run_query(sql: str, params: tuple) -> Optional[list]:
    """Run a query, handling missing table gracefully. Returns list of dicts or None on error."""
    import sqlite3
    try:
        import os
        db_path = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))
        # Read probe only — fail-fast at 2 s is intentional (probe should not stall the pipeline)
        with sqlite3.connect(db_path, timeout=2) as probe:
            probe.execute("SELECT 1 FROM incidents LIMIT 1")
        rows = db_query(sql, params)
        if rows is None:
            return []
        return [dict(r) for r in rows]
    except sqlite3.OperationalError as e:
        if "no such table" in str(e).lower():
            print(
                "(incidents table not yet initialized — run cast doctor)",
                file=sys.stderr,
            )
        else:
            logging.error(f"OperationalError querying incidents: {e}")
            print(f"(db error: {e})", file=sys.stderr)
        return None
    except Exception as e:
        logging.error(f"Unexpected error querying incidents: {e}")
        print(f"(unexpected error: {e})", file=sys.stderr)
        return None


def cmd_recent(args: argparse.Namespace) -> int:
    n = args.n
    status_filter = getattr(args, "status", "all")

    if status_filter and status_filter != "all":
        sql = (
            "SELECT id, occurred_at, problem_summary, fix_summary, "
            "related_files, related_commit, resolution_status, surfaced_by "
            "FROM incidents "
            "WHERE resolution_status = ? "
            "ORDER BY occurred_at DESC LIMIT ?"
        )
        params: tuple = (status_filter, n)
    else:
        sql = (
            "SELECT id, occurred_at, problem_summary, fix_summary, "
            "related_files, related_commit, resolution_status, surfaced_by "
            "FROM incidents "
            "ORDER BY occurred_at DESC LIMIT ?"
        )
        params = (n,)

    rows = _run_query(sql, params)
    if rows is None:
        return 0  # friendly message already printed

    if not rows:
        print("(no incidents)", file=sys.stderr)
        return 0

    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        for row in rows:
            print(_format_incident(row))

    return 0


def cmd_search(args: argparse.Namespace) -> int:
    kw = args.keyword
    pattern = f"%{kw}%"

    sql = (
        "SELECT id, occurred_at, problem_summary, fix_summary, "
        "related_files, related_commit, resolution_status, surfaced_by "
        "FROM incidents "
        "WHERE LOWER(problem_summary) LIKE LOWER(?) "
        "   OR LOWER(fix_summary) LIKE LOWER(?) "
        "ORDER BY occurred_at DESC"
    )
    params: tuple = (pattern, pattern)

    rows = _run_query(sql, params)
    if rows is None:
        return 0  # friendly message already printed

    if not rows:
        print("(no incidents)", file=sys.stderr)
        return 0

    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        for row in rows:
            print(_format_incident(row))

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Query the CAST incidents table",
        prog="cast-db-incidents",
    )
    subparsers = parser.add_subparsers(dest="subcommand", metavar="subcommand")
    subparsers.required = True

    # recent subcommand
    recent_parser = subparsers.add_parser(
        "recent",
        help="Show N most recent incidents (default 10)",
    )
    recent_parser.add_argument(
        "n",
        type=int,
        nargs="?",
        default=10,
        metavar="N",
        help="Number of incidents to show (default 10)",
    )
    recent_parser.add_argument(
        "--status",
        choices=["open", "fixed", "all"],
        default="all",
        help="Filter by resolution_status (default: all)",
    )
    recent_parser.add_argument(
        "--json",
        action="store_true",
        help="Output as JSON array",
    )

    # search subcommand
    search_parser = subparsers.add_parser(
        "search",
        help="Search incidents by keyword (LIKE on problem_summary and fix_summary)",
    )
    search_parser.add_argument(
        "keyword",
        metavar="keyword",
        help="Case-insensitive keyword to search",
    )
    search_parser.add_argument(
        "--json",
        action="store_true",
        help="Output as JSON array",
    )

    return parser


def main() -> int:
    _setup_logging()

    parser = build_parser()
    args = parser.parse_args()

    if args.subcommand == "recent":
        return cmd_recent(args)
    elif args.subcommand == "search":
        return cmd_search(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
