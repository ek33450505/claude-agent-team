#!/usr/bin/env python3
"""cast-db-drop-status-check.py — Drop the status CHECK constraint on agent_runs.

The original agent_runs.status column carried:
    CHECK (status IN ('DONE','DONE_WITH_CONCERNS','BLOCKED','NEEDS_CONTEXT','running','failed'))

That enum rejects real telemetry values that wired writers actually produce —
'abandoned' (cast-abandon-stale-runs.py), 'fallback' and 'unknown'
(cast-managed-agent.sh). The rejected UPDATE/INSERT throws sqlite3.IntegrityError,
which the writers swallow, so the rows are silently dropped. The agent-status
contract is enforced by hooks/agents, not by the database; agent_runs is an
observability table and should accept whatever status a writer records.

SQLite cannot ALTER a CHECK in place, so this recreates agent_runs WITHOUT the
CHECK while preserving EVERY column (including organically-added ones such as
duration_ms, tool_uses, abandoned_at), all data, the session_id foreign key,
and all indexes.

Idempotent: a no-op (exit 0) when agent_runs has no status CHECK. Safe to call on
every cast-db-init.sh run. Transactional with row-count verification + rollback.

Usage:
  cast-db-drop-status-check.py [DB_PATH]
  # DB_PATH defaults to $CAST_DB_PATH or ~/.claude/cast.db
"""

import os
import re
import sqlite3
import sys


def _resolve_db(argv: list) -> str:
    if len(argv) > 1 and argv[1]:
        return argv[1]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def _has_status_check(ddl: str) -> bool:
    """True if the agent_runs DDL carries a CHECK referencing status."""
    return bool(re.search(r'CHECK\s*\(\s*status\b', ddl, flags=re.IGNORECASE))


def _strip_status_check(ddl: str) -> str:
    """Remove the `CHECK (status IN (...))` clause from a CREATE TABLE statement.

    Preserves everything else (column types, defaults, the session_id foreign
    key). Returns the edited DDL.
    """
    # Match an optional leading space then CHECK ( status IN ( ... ) ). The inner
    # value list is single-quoted tokens with no embedded ')', so [^)]* is safe.
    pattern = re.compile(
        r'\s*CHECK\s*\(\s*status\s+IN\s*\([^)]*\)\s*\)',
        flags=re.IGNORECASE,
    )
    return pattern.sub('', ddl)


def main() -> int:
    db_path = _resolve_db(sys.argv)
    if not os.path.exists(db_path):
        # Nothing to migrate; not an error (fresh DBs are created elsewhere).
        return 0

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except sqlite3.Error as e:
        print(f"[drop-status-check] connect failed: {e}", file=sys.stderr)
        return 1

    try:
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='agent_runs'"
        ).fetchone()
        if not row or not row[0]:
            return 0  # no agent_runs table yet
        ddl = row[0]
        if not _has_status_check(ddl):
            return 0  # already clean — idempotent no-op

        new_ddl = _strip_status_check(ddl)
        if _has_status_check(new_ddl):
            print("[drop-status-check] could not strip CHECK from DDL; aborting (no changes made)",
                  file=sys.stderr)
            return 1
        # Build the temp-table DDL by renaming only the CREATE TABLE target.
        tmp_ddl = re.sub(
            r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["\[]?agent_runs["\]]?',
            'CREATE TABLE agent_runs__newschema',
            new_ddl,
            count=1,
            flags=re.IGNORECASE,
        )
        if 'agent_runs__newschema' not in tmp_ddl:
            print("[drop-status-check] could not rename CREATE target; aborting", file=sys.stderr)
            return 1

        # Preserve exact column order (incl. organically-added columns).
        cols = [r[1] for r in conn.execute("PRAGMA table_info(agent_runs)").fetchall()]
        if not cols:
            print("[drop-status-check] agent_runs has no columns?; aborting", file=sys.stderr)
            return 1
        col_list = ', '.join(f'"{c}"' for c in cols)

        # Capture index DDLs (skip auto-indexes which have sql IS NULL); they are
        # dropped with the old table and must be recreated against the new one.
        index_ddls = [
            r[0] for r in conn.execute(
                "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='agent_runs' AND sql IS NOT NULL"
            ).fetchall()
        ]

        before = conn.execute("SELECT COUNT(*) FROM agent_runs").fetchone()[0]

        # Foreign keys must be toggled outside a transaction.
        conn.execute("PRAGMA foreign_keys=OFF")
        try:
            conn.execute("BEGIN")
            conn.execute(tmp_ddl)
            conn.execute(
                f"INSERT INTO agent_runs__newschema ({col_list}) SELECT {col_list} FROM agent_runs"
            )
            after = conn.execute("SELECT COUNT(*) FROM agent_runs__newschema").fetchone()[0]
            if after != before:
                conn.rollback()
                print(f"[drop-status-check] row-count mismatch ({before} -> {after}); rolled back",
                      file=sys.stderr)
                return 1
            conn.execute("DROP TABLE agent_runs")
            conn.execute("ALTER TABLE agent_runs__newschema RENAME TO agent_runs")
            for idx in index_ddls:
                conn.execute(idx)
            conn.commit()
        except sqlite3.Error as e:
            conn.rollback()
            print(f"[drop-status-check] recreation failed; rolled back: {e}", file=sys.stderr)
            return 1
        finally:
            conn.execute("PRAGMA foreign_keys=ON")

        # Integrity sanity check post-swap.
        fk = conn.execute("PRAGMA foreign_key_check").fetchall()
        if fk:
            print(f"[drop-status-check] WARNING: foreign_key_check reported {len(fk)} issue(s)",
                  file=sys.stderr)

        print(f"[drop-status-check] removed agent_runs.status CHECK; preserved {before} rows "
              f"and {len(index_ddls)} index(es)", file=sys.stderr)
        return 0
    finally:
        conn.close()


if __name__ == '__main__':
    sys.exit(main())
