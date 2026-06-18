#!/usr/bin/env python3
"""cast-cron-summary.py — read-only daily agent_runs summary from cast.db.

Replaces the broken com.cast.cron-summary launchd job, which shelled out to the
interactive `claude` CLI non-interactively and failed every day (HTTP 401 — no
usable auth in launchd — plus the sandbox denied reading cast.db).

This opens cast.db strictly READ-ONLY (`?mode=ro`), never writes to it, needs no
network or auth, and writes a markdown summary to ~/.claude/reports/. Advisory:
exits 0 on every path, including a missing DB or table. Stdlib only.
"""
import os
import sqlite3
import datetime
import sys

DB_PATH = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))
REPORTS_DIR = os.path.expanduser("~/.claude/reports")
PROBLEM_STATUSES = ("failed", "BLOCKED", "DONE_WITH_CONCERNS", "abandoned")


def _write(path: str, lines: list) -> None:
    try:
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
    except OSError as e:
        print(f"[cast-cron-summary] could not write {path}: {e}", file=sys.stderr)


def main() -> int:
    today = datetime.date.today().isoformat()
    os.makedirs(REPORTS_DIR, exist_ok=True)
    out_path = os.path.join(REPORTS_DIR, f"daily-summary-{today}.md")
    lines = [f"# CAST Daily Summary — {today}", ""]

    if not os.path.exists(DB_PATH):
        lines.append(f"_cast.db not found at `{DB_PATH}`._")
        _write(out_path, lines)
        return 0

    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error as e:
        # fake-success-ok: honest degradation — surface the REAL error in the
        # report (not mock data) and exit 0 so the advisory launchd job never
        # fail-loops. The report tells the reader the DB was unreadable.
        lines.append(f"_Could not open cast.db read-only: {e}_")
        _write(out_path, lines)
        return 0

    try:
        cur = conn.cursor()
        rows = cur.execute(
            "SELECT status, COUNT(*) FROM agent_runs "
            "WHERE date(started_at)=date('now','localtime') "
            "GROUP BY status ORDER BY 2 DESC"
        ).fetchall()
        total = sum(c for _, c in rows)
        lines.append(f"**{total}** agent run(s) today.")
        lines.append("")
        if rows:
            lines.append("| Status | Count |")
            lines.append("|--------|-------|")
            for status, count in rows:
                lines.append(f"| {status or '(null)'} | {count} |")
            lines.append("")

        placeholders = ",".join("?" for _ in PROBLEM_STATUSES)
        problem = cur.execute(
            "SELECT agent, status, started_at FROM agent_runs "
            "WHERE date(started_at)=date('now','localtime') "
            f"AND status IN ({placeholders}) "
            "ORDER BY started_at DESC",
            PROBLEM_STATUSES,
        ).fetchall()
        if problem:
            lines.append("## Needs attention")
            lines.append("")
            for agent, status, ts in problem:
                lines.append(f"- `{agent or '?'}` — **{status}** ({ts})")
            lines.append("")
        else:
            lines.append("_No failed / BLOCKED / abandoned / DONE_WITH_CONCERNS runs today._")
    except sqlite3.Error as e:
        # fake-success-ok: surface the real query error in the report, not mock data.
        lines.append(f"_Query error (schema may differ): {e}_")
    finally:
        conn.close()

    _write(out_path, lines)
    print(f"[cast-cron-summary] wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
