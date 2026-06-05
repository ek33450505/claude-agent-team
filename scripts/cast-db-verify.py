#!/usr/bin/env python3
"""cast-db-verify.py — data-correctness verifier for cast.db.

Schema validity is checked elsewhere (`cast doctor`, cast-db-init.sh is the schema
single-source-of-truth). THIS tool verifies that the *data* satisfies its invariants:
referential integrity, value domains, temporal sanity, lifecycle hygiene, and known
corruption signatures (e.g. the §3.8.H truncation false-positive fallout).

Design:
- READ-ONLY. The DB is opened with `mode=ro`; the tool never writes.
- Tolerant. A check whose table/column is absent is SKIPPED, not failed, so the
  verifier runs against any cast.db regardless of schema drift.
- Gate-friendly. Exit 0 when all ERROR-severity checks pass; exit 1 on any ERROR
  violation; exit 2 when the DB cannot be opened. WARN violations never fail the gate
  unless --fail-on-warn is given.

Usage:
  python3 scripts/cast-db-verify.py [--db PATH] [--json] [--fail-on-warn] [--sample N]

DB path resolution: --db, else $CAST_DB_PATH, else ~/.claude/cast.db.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from dataclasses import dataclass, field
from typing import Callable, Optional

DEFAULT_DB = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))

# Value domains (kept in sync with the writers; '' tolerated where writers emit empties).
VALID_GATE_STATUS = ("DONE", "DONE_WITH_CONCERNS", "BLOCKED", "NEEDS_CONTEXT", "TRUNCATED", "")
VALID_RUN_STATUS = ("DONE", "running", "BLOCKED", "DONE_WITH_CONCERNS", "NEEDS_CONTEXT", "abandoned")
STALE_RUN_HOURS = 6  # a 'running' row older than this is almost certainly orphaned

# SQLite expr that normalizes our two timestamp dialects (ISO 'T..Z' and 'space/no-Z')
# to a julianday-comparable value. Centralized so every temporal check agrees.
_JD = "julianday(replace(replace({col}, 'T', ' '), 'Z', ''))"


@dataclass
class CheckResult:
    cid: str
    title: str
    severity: str  # 'error' | 'warn'
    status: str = "pass"  # 'pass' | 'fail' | 'skip'
    count: int = 0
    sample: list = field(default_factory=list)
    detail: str = ""

    def to_dict(self) -> dict:
        return {
            "id": self.cid,
            "title": self.title,
            "severity": self.severity,
            "status": self.status,
            "count": self.count,
            "sample": self.sample,
            "detail": self.detail,
        }


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (table,)
    ).fetchone()
    return row is not None


def _columns(conn: sqlite3.Connection, table: str) -> set:
    try:
        return {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    except sqlite3.Error:
        return set()


def _violation_count(conn: sqlite3.Connection, sql: str, params: tuple = ()) -> int:
    return int(conn.execute(sql, params).fetchone()[0])


def _sample_ids(conn: sqlite3.Connection, sql: str, params: tuple = (), limit: int = 5) -> list:
    try:
        return [r[0] for r in conn.execute(sql, params).fetchall()[:limit]]
    except sqlite3.Error:
        return []


# --- Individual checks ------------------------------------------------------
# Each check returns a CheckResult. They never raise on schema gaps — they SKIP.

def check_fk_integrity(conn: sqlite3.Connection, sample: int) -> list:
    """C1 — every child.session_id must exist in sessions.id."""
    results = []
    if not _table_exists(conn, "sessions"):
        results.append(CheckResult("C1", "referential integrity (session_id)", "error",
                                   status="skip", detail="sessions table absent"))
        return results
    children = ["agent_runs", "quality_gates", "agent_truncations",
                "routing_events", "dispatch_decisions"]
    for child in children:
        cid = f"C1.{child}"
        title = f"FK {child}.session_id → sessions.id"
        if not _table_exists(conn, child) or "session_id" not in _columns(conn, child):
            results.append(CheckResult(cid, title, "error", status="skip",
                                       detail="table/column absent"))
            continue
        where = ("session_id IS NOT NULL AND session_id NOT IN "
                 "(SELECT id FROM sessions)")
        n = _violation_count(conn, f"SELECT count(*) FROM {child} WHERE {where}")
        res = CheckResult(cid, title, "error", count=n,
                          status="fail" if n else "pass")
        if n:
            res.sample = _sample_ids(
                conn, f"SELECT session_id FROM {child} WHERE {where} LIMIT ?", (sample,), sample)
        results.append(res)
    return results


def check_truncation_fp(conn: sqlite3.Connection, sample: int) -> list:
    """C2 — structured-output (workflow) agents must never be in agent_truncations."""
    cid, title = "C2", "no workflow-subagent truncation false-positives"
    if not _table_exists(conn, "agent_truncations") or "agent_type" not in _columns(conn, "agent_truncations"):
        return [CheckResult(cid, title, "error", status="skip", detail="table/column absent")]
    where = "agent_type LIKE '%workflow-subagent%'"
    n = _violation_count(conn, f"SELECT count(*) FROM agent_truncations WHERE {where}")
    res = CheckResult(cid, title, "error", count=n, status="fail" if n else "pass")
    if n:
        res.sample = _sample_ids(
            conn, f"SELECT id FROM agent_truncations WHERE {where} ORDER BY id DESC LIMIT ?",
            (sample,), sample)
        res.detail = "F3 fallout — clean with DELETE; fixed forward by cast-subagent-stop-hook.sh"
    return [res]


def check_gate_status_domain(conn: sqlite3.Connection, sample: int) -> list:
    """C3 — quality_gates.status_line must be an enum value, not free text."""
    cid, title = "C3", "quality_gates.status_line domain"
    if not _table_exists(conn, "quality_gates") or "status_line" not in _columns(conn, "quality_gates"):
        return [CheckResult(cid, title, "error", status="skip", detail="table/column absent")]
    placeholders = ",".join("?" for _ in VALID_GATE_STATUS)
    where = f"status_line IS NOT NULL AND status_line NOT IN ({placeholders})"
    n = _violation_count(conn, f"SELECT count(*) FROM quality_gates WHERE {where}", VALID_GATE_STATUS)
    res = CheckResult(cid, title, "error", count=n, status="fail" if n else "pass")
    if n:
        res.sample = _sample_ids(
            conn, f"SELECT id FROM quality_gates WHERE {where} LIMIT ?",
            VALID_GATE_STATUS + (sample,), sample)
    return [res]


def check_run_status_domain(conn: sqlite3.Connection, sample: int) -> list:
    """C4 — agent_runs.status must be a known lifecycle value."""
    cid, title = "C4", "agent_runs.status domain"
    if not _table_exists(conn, "agent_runs") or "status" not in _columns(conn, "agent_runs"):
        return [CheckResult(cid, title, "error", status="skip", detail="table/column absent")]
    placeholders = ",".join("?" for _ in VALID_RUN_STATUS)
    where = f"status IS NOT NULL AND status NOT IN ({placeholders})"
    n = _violation_count(conn, f"SELECT count(*) FROM agent_runs WHERE {where}", VALID_RUN_STATUS)
    res = CheckResult(cid, title, "error", count=n, status="fail" if n else "pass")
    if n:
        res.sample = _sample_ids(
            conn, f"SELECT DISTINCT status FROM agent_runs WHERE {where} LIMIT ?",
            VALID_RUN_STATUS + (sample,), sample)
    return [res]


def check_stale_running(conn: sqlite3.Connection, sample: int) -> list:
    """C5 — no 'running' agent_runs older than STALE_RUN_HOURS (warn)."""
    cid, title = "C5", f"no stale 'running' runs (> {STALE_RUN_HOURS}h)"
    cols = _columns(conn, "agent_runs")
    if not _table_exists(conn, "agent_runs") or not {"status", "started_at"} <= cols:
        return [CheckResult(cid, title, "warn", status="skip", detail="table/columns absent")]
    age = f"julianday('now') - {_JD.format(col='started_at')}"
    where = f"status='running' AND started_at IS NOT NULL AND ({age}) > {STALE_RUN_HOURS / 24.0}"
    n = _violation_count(conn, f"SELECT count(*) FROM agent_runs WHERE {where}")
    res = CheckResult(cid, title, "warn", count=n, status="fail" if n else "pass")
    if n:
        res.sample = _sample_ids(
            conn, f"SELECT id FROM agent_runs WHERE {where} LIMIT ?", (sample,), sample)
        res.detail = "run cast-abandon-stale-runs.py to close these"
    return [res]


def check_temporal(conn: sqlite3.Connection, sample: int) -> list:
    """C6 — ended_at must not precede started_at (format-normalized)."""
    cid, title = "C6", "agent_runs ended_at >= started_at"
    cols = _columns(conn, "agent_runs")
    if not _table_exists(conn, "agent_runs") or not {"started_at", "ended_at"} <= cols:
        return [CheckResult(cid, title, "error", status="skip", detail="table/columns absent")]
    where = (f"ended_at IS NOT NULL AND started_at IS NOT NULL AND "
             f"{_JD.format(col='ended_at')} < {_JD.format(col='started_at')}")
    n = _violation_count(conn, f"SELECT count(*) FROM agent_runs WHERE {where}")
    res = CheckResult(cid, title, "error", count=n, status="fail" if n else "pass")
    if n:
        res.sample = _sample_ids(
            conn, f"SELECT id FROM agent_runs WHERE {where} LIMIT ?", (sample,), sample)
    return [res]


def check_timestamp_format(conn: sqlite3.Connection, sample: int) -> list:
    """C7 — agent_runs timestamps should be ISO-8601 (…T…Z) for consistent math (warn)."""
    cid, title = "C7", "agent_runs timestamps are ISO-8601 (T…Z)"
    cols = _columns(conn, "agent_runs")
    if not _table_exists(conn, "agent_runs") or not {"started_at", "ended_at"} <= cols:
        return [CheckResult(cid, title, "warn", status="skip", detail="table/columns absent")]
    where = ("(started_at IS NOT NULL AND started_at NOT LIKE '%T%Z') OR "
             "(ended_at IS NOT NULL AND ended_at NOT LIKE '%T%Z')")
    n = _violation_count(conn, f"SELECT count(*) FROM agent_runs WHERE {where}")
    res = CheckResult(cid, title, "warn", count=n, status="fail" if n else "pass")
    if n:
        res.sample = _sample_ids(
            conn, f"SELECT id FROM agent_runs WHERE {where} LIMIT ?", (sample,), sample)
        res.detail = "normalize writers (e.g. cast-abandon-stale-runs.py) to ISO-8601"
    return [res]


def check_memory_dedup(conn: sqlite3.Connection, sample: int) -> list:
    """C8 — agent_memories (agent, name) must be unique (dedup contract)."""
    cid, title = "C8", "agent_memories (agent,name) unique"
    cols = _columns(conn, "agent_memories")
    if not _table_exists(conn, "agent_memories") or not {"agent", "name"} <= cols:
        return [CheckResult(cid, title, "error", status="skip", detail="table/columns absent")]
    n = _violation_count(
        conn,
        "SELECT count(*) FROM (SELECT agent, name FROM agent_memories "
        "GROUP BY agent, name HAVING count(*) > 1)")
    res = CheckResult(cid, title, "error", count=n, status="fail" if n else "pass")
    if n:
        res.sample = _sample_ids(
            conn,
            "SELECT agent || '/' || name FROM agent_memories "
            "GROUP BY agent, name HAVING count(*) > 1 LIMIT ?", (sample,), sample)
    return [res]


def check_memory_completeness(conn: sqlite3.Connection, sample: int) -> list:
    """C9 — coverage of project/embedding/last_validated_at (warn; tracked by #7/#8/#9)."""
    cid, title = "C9", "agent_memories completeness (coverage)"
    cols = _columns(conn, "agent_memories")
    if not _table_exists(conn, "agent_memories"):
        return [CheckResult(cid, title, "warn", status="skip", detail="table absent")]
    total = _violation_count(conn, "SELECT count(*) FROM agent_memories")
    if total == 0:
        return [CheckResult(cid, title, "warn", status="pass", detail="no memories")]
    parts = []
    nulls = 0
    for col in ("project", "embedding", "last_validated_at"):
        if col in cols:
            c = _violation_count(conn, f"SELECT count(*) FROM agent_memories WHERE {col} IS NULL")
            parts.append(f"{col}={c}/{total} null")
            nulls += c
    res = CheckResult(cid, title, "warn", count=nulls,
                      status="fail" if nulls else "pass", detail="; ".join(parts))
    return [res]


def check_schema_columns_present(conn: sqlite3.Connection, sample: int) -> list:
    """C10 — init-authoritative columns must exist: agent_runs.(duration_ms,tool_uses) and dispatch_decisions.outcome."""
    results = []
    checks = [
        ("C10.agent_runs.duration_ms",      "agent_runs",        "duration_ms",  "error"),
        ("C10.agent_runs.tool_uses",         "agent_runs",        "tool_uses",    "error"),
        ("C10.dispatch_decisions.outcome",   "dispatch_decisions","outcome",      "error"),
    ]
    for cid, table, col, severity in checks:
        title = f"{table}.{col} column present (init-authoritative)"
        if not _table_exists(conn, table):
            results.append(CheckResult(cid, title, severity, status="skip",
                                       detail=f"{table} table absent"))
            continue
        present = col in _columns(conn, table)
        status = "pass" if present else "fail"
        detail = "" if present else (
            f"column missing — run cast-db-init.sh to self-heal; "
            f"drifted before v7.4.0 init-authoritative fix"
        )
        results.append(CheckResult(cid, title, severity, status=status, detail=detail))
    return results


CHECKS: list[Callable[[sqlite3.Connection, int], list]] = [
    check_fk_integrity,
    check_truncation_fp,
    check_gate_status_domain,
    check_run_status_domain,
    check_stale_running,
    check_temporal,
    check_timestamp_format,
    check_memory_dedup,
    check_memory_completeness,
    check_schema_columns_present,
]


def run_checks(db_path: str, sample: int) -> list:
    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        results: list = []
        for check in CHECKS:
            try:
                results.extend(check(conn, sample))
            except sqlite3.Error as exc:
                results.append(CheckResult(
                    getattr(check, "__name__", "?"), check.__doc__ or "", "error",
                    status="skip", detail=f"sqlite error: {exc}"))
        return results
    finally:
        conn.close()


def _emit_human(results: list, db_path: str) -> None:
    print(f"CAST DB VERIFY — {db_path}")
    icons = {"pass": "✅", "fail": "❌", "skip": "·"}
    for r in results:
        line = f"  {icons.get(r.status, '?')} [{r.severity.upper():5}] {r.cid:14} {r.title}"
        if r.status == "fail":
            line += f"  → {r.count} violation(s)"
            if r.sample:
                line += f" {r.sample}"
        elif r.status == "skip":
            line += f"  (skip: {r.detail})"
        print(line)
        if r.status == "fail" and r.detail:
            print(f"        ↳ {r.detail}")


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description="Verify cast.db data correctness (read-only).")
    parser.add_argument("--db", default=DEFAULT_DB, help="path to cast.db")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--fail-on-warn", action="store_true", help="warns also fail the gate")
    parser.add_argument("--sample", type=int, default=5, help="sample ids to show per failure")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.db):
        print(json.dumps({"error": f"db not found: {args.db}"}) if args.json
              else f"ERROR: db not found: {args.db}", file=sys.stderr)
        return 2

    try:
        results = run_checks(args.db, args.sample)
    except sqlite3.Error as exc:
        print(json.dumps({"error": str(exc)}) if args.json
              else f"ERROR: cannot open db: {exc}", file=sys.stderr)
        return 2

    errors = sum(1 for r in results if r.status == "fail" and r.severity == "error")
    warns = sum(1 for r in results if r.status == "fail" and r.severity == "warn")
    passes = sum(1 for r in results if r.status == "pass")
    skips = sum(1 for r in results if r.status == "skip")

    if args.json:
        print(json.dumps({
            "db": args.db,
            "summary": {"pass": passes, "error_fail": errors, "warn_fail": warns, "skip": skips},
            "checks": [r.to_dict() for r in results],
        }, indent=2))
    else:
        _emit_human(results, args.db)
        print(f"\nSummary: {passes} pass · {errors} error · {warns} warn · {skips} skip")

    if errors or (args.fail_on_warn and warns):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
