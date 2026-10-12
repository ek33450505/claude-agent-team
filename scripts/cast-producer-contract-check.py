#!/usr/bin/env python3
"""cast-producer-contract-check.py — Validates config/producer-contract.json against reality.

That contract feeds the cast-desktop pipeline-health view / dashboard (per its
own "consumers" header field): each table declares the script(s) that write it
and a status (live/dormant/external/dead_writer_retired/...). Nothing
previously checked that a "live" table's declared writers still exist — a
script rename or retirement could leave the contract pointing at nothing,
silently lying to the dashboard. This closes that gap (audit MED, 2026-08-04).

Checks: every `writers` entry belonging to a `"status": "live"` table must
resolve to a real file on disk. If the entry also carries a numeric `:line`
suffix, that line number must be within the file's line count AND the cited
line's text must contain the table name as a whole identifier (\\btable\\b)
plus a write marker (INSERT, REPLACE, UPDATE, db_write, db_execute,
_db_execute; case-insensitive). A writer that writes only indirectly (via a
helper) must use the non-numeric `file:funcname (description)` form. A bare
identifier suffix (`[A-Za-z_][A-Za-z0-9_]*`) must appear as a whole word on at
least one non-comment line of the file; other suffixes and no suffix are
file-existence only. Known residual: a numeric ref landing on a comment line
that names the table and a verb still passes. Non-"live"
statuses (dormant, external, dead_writer_retired, retired_this_session, ...)
are intentionally NOT checked — an empty or free-text `writers` list is
expected for those.

Writer string formats seen in the contract (first whitespace-separated token
is what gets resolved; any trailing "(description)" text is documentation
only and ignored):
  "file.sh:123"                      — file + line number
  "file.py:funcname (description)"   — file + non-numeric suffix, no line check
  "file.py (description)"            — file only, no line check
  "dir/file:123"                     — path with a subdir, relative to repo root

A bare filename (no "/") resolves under scripts/. Anything containing "/"
resolves relative to the repo root (e.g. "bin/cast:1417").

Usage:
  scripts/cast-producer-contract-check.py [--contract PATH]
Exit 0 — every live-table writer resolves (also printed to stdout).
Exit 1 — one or more dangling writers found (listed on stderr) OR the
         contract file itself is missing / not valid JSON.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_CONTRACT = REPO_ROOT / "config" / "producer-contract.json"


def _resolve(file_part: str) -> Path:
    """Resolve a writer's file token: bare filename -> scripts/, else repo-root-relative."""
    if "/" in file_part:
        return REPO_ROOT / file_part
    return SCRIPT_DIR / file_part


_WRITE_MARKER = re.compile(r"\b(?:INSERT|REPLACE|UPDATE)\b|db_write|_?db_execute", re.IGNORECASE)
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _check_writer(writer: str, table: str = "") -> str | None:
    """Return an error message if `writer` is dangling, else None."""
    token = writer.split()[0] if writer.split() else writer
    file_part, _, line_part = token.partition(":")

    path = _resolve(file_part)
    if not path.is_file():
        return f"file not found: {file_part!r} (writer: {writer!r}, resolved: {path})"

    if line_part.isdigit():
        line_no = int(line_part)
        with path.open(encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
        if line_no > len(lines) or line_no < 1:
            return (
                f"line {line_no} out of range for {file_part!r} "
                f"({len(lines)} lines total; writer: {writer!r})"
            )
        text = lines[line_no - 1]
        if not (re.search(rf"\b{re.escape(table)}\b", text) and _WRITE_MARKER.search(text)):
            return f"line {line_no} of {file_part} does not write {table}: {text.strip()[:100]}"
    elif _IDENT.match(line_part):
        with path.open(encoding="utf-8", errors="replace") as f:
            code = [ln for ln in f.read().split("\n") if not ln.lstrip().startswith("#")]
        if not any(re.search(rf"\b{re.escape(line_part)}\b", ln) for ln in code):
            return f"identifier {line_part} not found in {file_part}"
    return None


def check_contract(contract: dict) -> list[str]:
    """Return a list of dangling-writer error messages (empty = clean)."""
    errors: list[str] = []
    for entry in contract.get("tables", []):
        if entry.get("status") != "live":
            continue
        table = entry.get("table", "<unknown>")
        for writer in entry.get("writers", []):
            err = _check_writer(writer, table)
            if err:
                errors.append(f"table {table!r}: {err}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--contract",
        type=Path,
        default=DEFAULT_CONTRACT,
        help="Path to producer-contract.json (default: config/producer-contract.json)",
    )
    args = parser.parse_args()

    if not args.contract.is_file():
        print(f"cast-producer-contract-check: contract not found: {args.contract}", file=sys.stderr)
        return 1

    try:
        with args.contract.open(encoding="utf-8") as f:
            contract = json.load(f)
    except json.JSONDecodeError as e:
        print(f"cast-producer-contract-check: invalid JSON in {args.contract}: {e}", file=sys.stderr)
        return 1

    errors = check_contract(contract)

    if errors:
        print(f"cast-producer-contract-check: {len(errors)} dangling live-table writer(s):", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"cast-producer-contract-check: OK ({args.contract})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
