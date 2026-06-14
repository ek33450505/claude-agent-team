#!/usr/bin/env python3
"""
CAST Write-Only Table Detector

Parses scripts/cast-db-init.sh to extract every CREATE TABLE name, then
searches scripts/ bin/ skills/ agents/ for read evidence (SELECT...FROM or
FROM <table>). Tables with zero read sites are reported as warnings.

This is an ADVISORY gate — it always exits 0 so it cannot break CI.
Use --strict to exit 1 when any warnings are found (future ratcheting).

Exit codes:
  0 — no warnings, or warnings found but --strict not set
  1 — warnings found and --strict flag is set

Override paths via environment variables:
  CAST_DB_INIT_PATH  — path to cast-db-init.sh (default: <repo>/scripts/cast-db-init.sh)
  CAST_REPO_ROOT     — repo root for scanning (default: git rev-parse --show-toplevel)
"""

import os
import re
import sys

# Tables that are intentionally write-only meta/bookkeeping tables.
# These track schema evolution and are never queried at runtime.
ALLOWLIST = {
    "schema_migrations",
}

# Directories (relative to repo root) to search for read evidence.
SEARCH_DIRS = ["scripts", "bin", "skills", "agents"]

# Pattern: FROM <table> with word boundaries (catches both bare FROM and SELECT...FROM).
# We exclude matches inside sqlite_master checks like:
#   SELECT name FROM sqlite_master WHERE ... AND name='<table>'
# because those are schema introspection, not data reads.
READ_PATTERN_TEMPLATE = r"\bFROM\s+{table}\b"


def get_repo_root():
    """Get the repository root directory."""
    try:
        result = os.popen("git rev-parse --show-toplevel 2>/dev/null").read().strip()
        if result:
            return result
    except Exception:
        pass
    return os.getcwd()


def parse_table_names(db_init_path):
    """Extract CREATE TABLE [IF NOT EXISTS] names from cast-db-init.sh."""
    tables = []
    pattern = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([a-z_][a-z0-9_]*)",
        re.IGNORECASE,
    )
    try:
        with open(db_init_path, "r") as f:
            for line in f:
                stripped = line.strip()
                # Skip comment lines
                if stripped.startswith("#"):
                    continue
                m = pattern.search(stripped)
                if m:
                    name = m.group(1).lower()
                    if name not in tables:
                        tables.append(name)
    except OSError as e:
        print(f"ERROR [lint-write-only-tables]: Cannot read {db_init_path}: {e}", file=sys.stderr)
        sys.exit(1)
    return tables


def find_read_sites(repo_root, table):
    """Return list of file paths that contain a data read of <table>."""
    pattern = re.compile(READ_PATTERN_TEMPLATE.format(table=re.escape(table)))
    sqlite_master_pat = re.compile(r"sqlite_master")
    hits = []

    for dir_name in SEARCH_DIRS:
        dir_path = os.path.join(repo_root, dir_name)
        if not os.path.isdir(dir_path):
            continue
        for root, _dirs, files in os.walk(dir_path):
            for fname in files:
                # Only scan text-ish files; skip compiled Python caches
                if fname.endswith(".pyc") or fname.endswith(".pyo"):
                    continue
                fpath = os.path.join(root, fname)
                try:
                    with open(fpath, "r", errors="replace") as f:
                        for line in f:
                            if pattern.search(line) and not sqlite_master_pat.search(line):
                                hits.append(fpath)
                                break  # one hit per file is enough
                except OSError:
                    continue
    return hits


def main():
    strict = "--strict" in sys.argv

    repo_root = os.environ.get("CAST_REPO_ROOT") or get_repo_root()
    db_init_path = os.environ.get("CAST_DB_INIT_PATH") or os.path.join(
        repo_root, "scripts", "cast-db-init.sh"
    )

    if not os.path.exists(db_init_path):
        print(
            f"WARNING [lint-write-only-tables]: {db_init_path} not found. Skipping check.",
            file=sys.stderr,
        )
        return 0

    tables = parse_table_names(db_init_path)
    if not tables:
        return 0

    warnings = []
    for table in sorted(tables):
        if table in ALLOWLIST:
            continue
        hits = find_read_sites(repo_root, table)
        if not hits:
            warnings.append(table)

    for table in warnings:
        print(
            f"WARN [lint-write-only-tables]: {table} — created but never read in this repo"
        )

    if warnings:
        print(
            f"\nSummary: {len(warnings)} write-only table(s) out of {len(tables)} total "
            f"({len(ALLOWLIST)} allowlisted)."
        )

    if strict and warnings:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
