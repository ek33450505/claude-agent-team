#!/usr/bin/env python3
"""cast-commit-provenance.py — record and check commit provenance for D5 self-commit enforcement.

Subcommands:
  record <sha>  — insert a provenance row for the given commit SHA (INSERT OR IGNORE)
  check <sha>   — exit 0 + {"found": true} if row exists; exit 1 + {"found": false} otherwise
                  NOTE: matches the FULL 40-char SHA exactly; no short-SHA normalization.

Both subcommands reject sha values that do not match ^[0-9a-fA-F]{7,64}$ (git SHA format guard).

Uses CAST_DB_PATH env var (falls back to ~/.claude/cast.db).
Stdlib only. Always emits valid JSON on stdout; errors to stderr.
"""

import datetime
import json
import os
import re
import subprocess
import sys

# Import cast_db abstraction — standard pattern for scripts in this directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cast_db import db_execute, db_query  # noqa: E402


def _git(*args: str) -> str:
    """Run a git command and return stripped stdout, or '' on failure."""
    try:
        result = subprocess.run(
            ["git"] + list(args),
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except Exception:
        return ""


def cmd_record(sha: str) -> int:
    """Insert a provenance row. INSERT OR IGNORE for idempotency."""
    session_id = os.environ.get("CLAUDE_SESSION_ID", "")
    branch = _git("rev-parse", "--abbrev-ref", "HEAD")
    repo = _git("rev-parse", "--show-toplevel")
    recorded_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        ok = db_execute(
            "INSERT OR IGNORE INTO commit_provenance (sha, session_id, agent, branch, repo, recorded_at)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (sha, session_id, "commit", branch, repo, recorded_at),
        )
        if ok:
            print(json.dumps({"recorded": sha}))
            return 0
        else:
            print(json.dumps({"error": "db_execute returned False — check db-write-errors.log"}))
            print("cast-commit-provenance: record failed — db_execute returned False", file=sys.stderr)
            return 1
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        print(f"cast-commit-provenance: record failed: {exc}", file=sys.stderr)
        return 1


def cmd_check(sha: str) -> int:
    """Exit 0 + {"found": true} if row exists; exit 1 + {"found": false} otherwise."""
    try:
        rows = db_query(
            "SELECT sha FROM commit_provenance WHERE sha = ?",
            (sha,),
        )
        if rows:
            print(json.dumps({"found": True}))
            return 0
        else:
            print(json.dumps({"found": False}))
            return 1
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        print(f"cast-commit-provenance: check failed: {exc}", file=sys.stderr)
        return 1


def main() -> int:
    if len(sys.argv) < 3:
        print(json.dumps({"error": "usage: cast-commit-provenance.py <record|check> <sha>"}))
        return 1

    subcommand = sys.argv[1]
    sha = sys.argv[2]

    if not re.match(r'^[0-9a-fA-F]{7,64}$', sha):
        print(json.dumps({"error": "invalid sha format"}))
        return 1

    if subcommand == "record":
        return cmd_record(sha)
    elif subcommand == "check":
        return cmd_check(sha)
    else:
        print(json.dumps({"error": f"unknown subcommand: {subcommand}"}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
