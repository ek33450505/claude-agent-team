#!/usr/bin/env python3
"""cast-ledger.py — Signed per-session audit receipt renderer for CAST.

CLI: cast-ledger.py [SESSION_ID] [--last N] [--since YYYY-MM-DD]
                    [--json] [--out FILE] [--verify FILE] [--db PATH]

Renders a human-readable, SHA-256-stamped session receipt entirely from cast.db.
Strictly read-only; never writes to the database.
Never crashes — every section is wrapped in fail-open try/except.
"""

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


ALLOWED_INTEGRITY_TABLES = frozenset({
    "agent_protocol_violations", "agent_hallucinations",
    "agent_truncations", "completeness_events",
})
# Raw agent-output / freetext columns that must NEVER be exported into a portable receipt.
_INTEGRITY_FREETEXT_COLS = frozenset({
    "raw_excerpt", "partial_work_log", "claimed_value", "actual_value",
    "snippet", "response", "content", "prompt", "prompt_preview",
    "message", "body", "detail", "details", "work_log", "output",
    "stdout", "stderr", "last_line",
})


# ── DB path resolution (mirrors cast-ask-query.py lines 39-62) ───────────────

def _get_db_path(override: str = "") -> str:
    if override:
        return override
    url = os.environ.get("CAST_DB_URL", "")
    if url.startswith("sqlite:///"):
        return url[len("sqlite:///"):]
    return os.environ.get(
        "CAST_DB_PATH",
        str(Path.home() / ".claude" / "cast.db"),
    )


def _connect(db_path: str) -> sqlite3.Connection:
    # Strict read-only: open with mode=ro so the renderer can NEVER write to cast.db.
    # (No WAL pragma — switching journal mode is a write; and this must work against a
    # read-only-mounted replica, e.g. the off-blast-radius backup / Litestream copy.)
    ro_uri = "file://" + urllib.parse.quote(os.path.abspath(db_path)) + "?mode=ro"
    conn = sqlite3.connect(ro_uri, uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA busy_timeout=5000;")
    except Exception:
        pass
    return conn


# ── Session resolution ────────────────────────────────────────────────────────

def _fetch_session(conn: sqlite3.Connection, session_id: str) -> Optional[sqlite3.Row]:
    """Return the sessions row for session_id, or None if not found."""
    try:
        row = conn.execute(
            "SELECT id, project, project_root, started_at, ended_at, status "
            "FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        return row
    except sqlite3.OperationalError:
        return None
    except Exception:
        return None


def _fetch_most_recent_session(conn: sqlite3.Connection) -> Optional[sqlite3.Row]:
    """Return the session with the latest started_at."""
    try:
        row = conn.execute(
            "SELECT id, project, project_root, started_at, ended_at, status "
            "FROM sessions ORDER BY started_at DESC, rowid DESC LIMIT 1"
        ).fetchone()
        return row
    except sqlite3.OperationalError:
        return None
    except Exception:
        return None


def _fetch_last_n_sessions(conn: sqlite3.Connection, n: int) -> List[sqlite3.Row]:
    """Return the N most-recent sessions ordered most-recent first."""
    try:
        rows = conn.execute(
            "SELECT id, project, project_root, started_at, ended_at, status "
            "FROM sessions ORDER BY started_at DESC, rowid DESC LIMIT ?",
            (n,),
        ).fetchall()
        return rows
    except sqlite3.OperationalError:
        return []
    except Exception:
        return []


def _fetch_sessions_since(conn: sqlite3.Connection, since: str) -> List[sqlite3.Row]:
    """Return sessions with started_at >= since, most-recent first."""
    try:
        rows = conn.execute(
            "SELECT id, project, project_root, started_at, ended_at, status "
            "FROM sessions WHERE started_at >= ? "
            "ORDER BY started_at DESC, rowid DESC",
            (since,),
        ).fetchall()
        return rows
    except sqlite3.OperationalError:
        return []
    except Exception:
        return []


# ── Section data collectors ───────────────────────────────────────────────────

def _fetch_agent_runs(conn: sqlite3.Connection, session_id: str) -> List[Dict]:
    """Fetch agent_runs rows for the session, ordered by started_at then rowid."""
    try:
        rows = conn.execute(
            "SELECT agent, model, status, started_at, ended_at, "
            "input_tokens, output_tokens, cost_usd, "
            "cache_read_input_tokens, cache_creation_input_tokens, "
            "owns_files, duration_ms, tool_uses "
            "FROM agent_runs "
            "WHERE session_id = ? "
            "ORDER BY started_at, rowid",
            (session_id,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    except Exception:
        return []


def _fetch_file_writes(conn: sqlite3.Connection, session_id: str) -> List[Dict]:
    """Fetch file_writes rows ordered by ts, file_path."""
    try:
        rows = conn.execute(
            "SELECT file_path, tool_name, agent_name, ts "
            "FROM file_writes "
            "WHERE session_id = ? "
            "ORDER BY ts, file_path",
            (session_id,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    except Exception:
        return []


def _fetch_routing_events(conn: sqlite3.Connection, session_id: str) -> List[Dict]:
    """Fetch routing_events rows ordered by timestamp."""
    try:
        rows = conn.execute(
            "SELECT action, matched_route, pattern, event_type, timestamp "
            "FROM routing_events "
            "WHERE session_id = ? "
            "ORDER BY timestamp",
            (session_id,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    except Exception:
        return []


def _fetch_quality_gates(conn: sqlite3.Connection, session_id: str) -> List[Dict]:
    """Fetch quality_gates rows ordered by created_at."""
    try:
        rows = conn.execute(
            "SELECT agent_name, gate_type, contract_passed, retry_count, created_at "
            "FROM quality_gates "
            "WHERE session_id = ? "
            "ORDER BY created_at",
            (session_id,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    except Exception:
        return []


def _fetch_integrity_table(conn: sqlite3.Connection, table: str, session_id: str) -> List[Dict]:
    """Fetch SAFE (non-freetext) columns from an integrity table for session_id. Fail-open.

    The receipt is a portable export, so raw agent-output columns (raw_excerpt,
    partial_work_log, etc.) are NEVER included — only counts + safe descriptors.
    """
    if table not in ALLOWED_INTEGRITY_TABLES:
        return []
    try:
        cols = [r["name"] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()]
        if not cols or "session_id" not in cols:
            return []
        safe_cols = [c for c in cols if c.lower() not in _INTEGRITY_FREETEXT_COLS]
        if not safe_cols:
            return []
        col_sql = ", ".join('"' + c + '"' for c in safe_cols)
        rows = conn.execute(
            f'SELECT {col_sql} FROM "{table}" WHERE session_id = ?',  # table allowlisted; cols from schema
            (session_id,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    except Exception:
        return []


# ── Canonical data dict builder ───────────────────────────────────────────────

def _build_receipt_data(
    conn: sqlite3.Connection,
    session_row: sqlite3.Row,
) -> Dict[str, Any]:
    """Build the canonical data dict D for a session. No wall-clock timestamps."""
    sid = session_row["id"]

    # Session header
    session_data: Dict[str, Any] = {
        "id": sid,
        "project": session_row["project"],
        "project_root": session_row["project_root"],
        "started_at": session_row["started_at"],
        "ended_at": session_row["ended_at"],
        "status": session_row["status"],
    }

    agents = _fetch_agent_runs(conn, sid)
    files = _fetch_file_writes(conn, sid)
    routes = _fetch_routing_events(conn, sid)
    gates = _fetch_quality_gates(conn, sid)

    # Compute totals from agent_runs
    total_input = sum(int(a.get("input_tokens") or 0) for a in agents)
    total_output = sum(int(a.get("output_tokens") or 0) for a in agents)
    total_cache_read = sum(int(a.get("cache_read_input_tokens") or 0) for a in agents)
    total_cache_creation = sum(int(a.get("cache_creation_input_tokens") or 0) for a in agents)
    total_cost = sum(float(a.get("cost_usd") or 0.0) for a in agents)

    # Distinct models (preserve order of first appearance)
    seen: set = set()
    models: List[str] = []
    for a in agents:
        m = a.get("model") or ""
        if m and m not in seen:
            seen.add(m)
            models.append(m)

    totals: Dict[str, Any] = {
        "models": models,
        "input_tokens": total_input,
        "output_tokens": total_output,
        "cache_read_input_tokens": total_cache_read,
        "cache_creation_input_tokens": total_cache_creation,
        "cost_usd": total_cost,
    }

    # Integrity tables (defensive)
    integrity_tables = [
        "agent_protocol_violations",
        "agent_hallucinations",
        "agent_truncations",
        "completeness_events",
    ]
    integrity: Dict[str, Any] = {}
    for tbl in integrity_tables:
        rows = _fetch_integrity_table(conn, tbl, sid)
        integrity[tbl] = rows

    return {
        "session": session_data,
        "totals": totals,
        "agents": agents,
        "files": files,
        "routes": routes,
        "gates": gates,
        "integrity": integrity,
    }


# ── Digest computation ────────────────────────────────────────────────────────

def _compute_digest(data: Dict[str, Any]) -> str:
    """Compute deterministic SHA-256 digest of the canonical data dict."""
    serialized = json.dumps(
        data,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        default=str,
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(serialized).hexdigest()


# ── Duration helper ───────────────────────────────────────────────────────────

def _duration_str(started_at: Optional[str], ended_at: Optional[str]) -> Optional[str]:
    """Return a human-readable duration string, or None if either timestamp is absent."""
    if not started_at or not ended_at:
        return None
    try:
        import datetime
        fmt = "%Y-%m-%dT%H:%M:%S"
        # Handle optional microseconds / Z suffix
        def _parse(ts: str):
            ts = ts.replace("Z", "").split(".")[0]
            return datetime.datetime.strptime(ts, fmt)
        delta = _parse(ended_at) - _parse(started_at)
        total_seconds = int(delta.total_seconds())
        if total_seconds < 0:
            return None
        h, rem = divmod(total_seconds, 3600)
        m, s = divmod(rem, 60)
        if h:
            return f"{h}h {m}m {s}s"
        if m:
            return f"{m}m {s}s"
        return f"{s}s"
    except Exception:
        return None


# ── Markdown renderer ─────────────────────────────────────────────────────────

def _render_markdown(data: Dict[str, Any], digest: str) -> str:
    lines: List[str] = []

    sess = data["session"]
    totals = data["totals"]
    agents = data["agents"]
    files = data["files"]
    routes = data["routes"]
    gates = data["gates"]
    integrity = data["integrity"]

    lines.append("# CAST Session Receipt")
    lines.append("")

    # Header bullets
    lines.append(f"- **Session:** {sess['id']}")
    proj = sess.get("project") or ""
    root = sess.get("project_root") or ""
    if proj or root:
        lines.append(f"- **Project:** {proj} ({root})")
    lines.append(f"- **Started:** {sess.get('started_at') or '—'}")
    lines.append(f"- **Ended:** {sess.get('ended_at') or '—'}")
    dur = _duration_str(sess.get("started_at"), sess.get("ended_at"))
    if dur:
        lines.append(f"- **Duration:** {dur}")
    lines.append(f"- **Status:** {sess.get('status') or '—'}")
    lines.append("")

    # Models & Cost
    lines.append("## Models & Cost")
    lines.append("")
    models_str = ", ".join(totals["models"]) if totals["models"] else "—"
    lines.append(f"- **Models:** {models_str}")
    lines.append(f"- **Input tokens:** {totals['input_tokens']:,}")
    lines.append(f"- **Output tokens:** {totals['output_tokens']:,}")
    lines.append(f"- **Cache read tokens:** {totals['cache_read_input_tokens']:,}")
    lines.append(f"- **Cache creation tokens:** {totals['cache_creation_input_tokens']:,}")
    lines.append(f"- **Total cost:** ${totals['cost_usd']:.4f}")
    lines.append("")

    # Agents
    lines.append(f"## Agents ({len(agents)})")
    lines.append("")
    if agents:
        lines.append("| Agent | Model | Status | Duration (ms) | Cost (USD) | Tool Uses |")
        lines.append("|-------|-------|--------|---------------|------------|-----------|")
        for a in agents:
            agent_name = a.get("agent") or "—"
            model = a.get("model") or "—"
            status = a.get("status") or "—"
            dur_ms = a.get("duration_ms")
            cost = a.get("cost_usd")
            tools = a.get("tool_uses")
            cost_str = f"{float(cost):.4f}" if cost is not None else "—"
            lines.append(
                f"| {agent_name} | {model} | {status} | "
                f"{dur_ms if dur_ms is not None else '—'} | "
                f"{cost_str} | "
                f"{tools if tools is not None else '—'} |"
            )
    else:
        lines.append("No agent activity recorded.")
    lines.append("")

    # Files Changed
    distinct_files = len({f.get("file_path") for f in files})
    lines.append(f"## Files Changed ({distinct_files})")
    lines.append("")
    if files:
        lines.append("| File | Tool | Agent |")
        lines.append("|------|------|-------|")
        for f in files:
            fp = f.get("file_path") or "—"
            tool = f.get("tool_name") or "—"
            agent = f.get("agent_name") or "—"
            lines.append(f"| {fp} | {tool} | {agent} |")
    else:
        lines.append("No file writes recorded.")
    lines.append("")

    # Decisions & Gates
    lines.append("## Decisions & Gates")
    lines.append("")
    if routes:
        lines.append("**Routes:**")
        lines.append("")
        for r in routes:
            action = r.get("action") or "—"
            matched = r.get("matched_route") or "—"
            etype = r.get("event_type") or "—"
            lines.append(f"- `{action}` / `{matched}` / `{etype}`")
        lines.append("")
    if gates:
        lines.append("**Gates:**")
        lines.append("")
        for g in gates:
            agent_name = g.get("agent_name") or "—"
            gtype = g.get("gate_type") or "—"
            passed = g.get("contract_passed")
            retries = g.get("retry_count") or 0
            passed_str = str(passed) if passed is not None else "—"
            lines.append(f"- `{agent_name}` / `{gtype}` / passed={passed_str} / retries={retries}")
        lines.append("")
    if not routes and not gates:
        lines.append("No routing events or quality gates recorded.")
        lines.append("")

    # Integrity
    lines.append("## Integrity")
    lines.append("")
    integrity_labels = {
        "agent_protocol_violations": "Protocol violations",
        "agent_hallucinations": "Hallucinations",
        "agent_truncations": "Truncations",
        "completeness_events": "Completeness flags",
    }
    any_nonzero = False
    for tbl, label in integrity_labels.items():
        rows = integrity.get(tbl, [])
        count = len(rows)
        lines.append(f"- **{label}:** {count}")
        if count > 0:
            any_nonzero = True

    if any_nonzero:
        lines.append("")
        for tbl, label in integrity_labels.items():
            rows = integrity.get(tbl, [])
            if rows:
                lines.append(f"**{label} detail:**")
                lines.append("")
                for row in rows:
                    brief = {k: v for k, v in row.items() if k != "session_id"}
                    lines.append(f"- {brief}")
                lines.append("")

    lines.append("")
    lines.append("---")
    lines.append(f"Digest: {digest}")

    return "\n".join(lines)


# ── Verify mode ───────────────────────────────────────────────────────────────

def _extract_pairs_markdown(content: str) -> List[Tuple[str, str]]:
    """Extract (session_id, digest) pairs from a markdown receipt file."""
    pairs: List[Tuple[str, str]] = []
    session_ids: List[str] = []
    digests: List[str] = []

    for line in content.splitlines():
        # Match: - **Session:** <id>
        m = re.match(r"[-*]\s*\*\*Session:\*\*\s*(.+)", line.strip())
        if m:
            session_ids.append(m.group(1).strip())
        # Match: Digest: sha256:<hex>
        m2 = re.match(r"Digest:\s*(sha256:[0-9a-f]+)", line.strip())
        if m2:
            digests.append(m2.group(1).strip())

    if len(session_ids) != len(digests):
        print(
            f"cast ledger: malformed receipt — {len(session_ids)} session header(s) "
            f"but {len(digests)} digest(s); refusing to verify",
            file=sys.stderr,
        )
        return []

    for sid, dig in zip(session_ids, digests):
        pairs.append((sid, dig))
    return pairs


def _extract_pairs_json(content: str) -> List[Tuple[str, str]]:
    """Extract (session_id, digest) pairs from a JSON receipt file."""
    try:
        data = json.loads(content)
        if isinstance(data, list):
            items = data
        else:
            items = [data]
        pairs = []
        for item in items:
            sid = item.get("receipt", {}).get("session", {}).get("id")
            digest = item.get("digest")
            if sid and digest:
                pairs.append((sid, digest))
        return pairs
    except Exception:
        return []


def _cmd_verify(file_path: str, conn: sqlite3.Connection) -> int:
    """Verify a receipt file. Returns 0 for PASS, 1 for TAMPERED/unverifiable."""
    try:
        with open(file_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except OSError as e:
        print(f"cast ledger: cannot read file: {e}", file=sys.stderr)
        return 1

    # Detect format
    stripped = content.strip()
    if stripped.startswith("{") or stripped.startswith("["):
        pairs = _extract_pairs_json(content)
    else:
        pairs = _extract_pairs_markdown(content)

    if not pairs:
        print("cast ledger: no session/digest pairs found in file", file=sys.stderr)
        return 1

    all_pass = True
    for sid, embedded_digest in pairs:
        session_row = _fetch_session(conn, sid)
        if session_row is None:
            print(f"VERIFY: TAMPERED (session {sid}: not found in cast.db — unverifiable)")
            all_pass = False
            continue
        data = _build_receipt_data(conn, session_row)
        rederived = _compute_digest(data)
        if rederived == embedded_digest:
            # individual pass — only print overall at the end
            pass
        else:
            print(f"VERIFY: TAMPERED (session {sid}: expected {embedded_digest} got {rederived})")
            all_pass = False

    if all_pass:
        print("VERIFY: PASS")
        return 0
    return 1


# ── Output dispatch ───────────────────────────────────────────────────────────

def _render_session(
    conn: sqlite3.Connection,
    session_row: sqlite3.Row,
    as_json: bool,
) -> Tuple[str, Dict[str, Any]]:
    """Return (rendered_string, canonical_data_dict) for one session."""
    data = _build_receipt_data(conn, session_row)
    digest = _compute_digest(data)
    if as_json:
        obj = {"receipt": data, "digest": digest}
        rendered = json.dumps(obj, sort_keys=True, indent=2, default=str)
    else:
        rendered = _render_markdown(data, digest)
    return rendered, {"receipt": data, "digest": digest}


def _output(text: str, out_file: Optional[str]) -> None:
    if out_file:
        p = Path(out_file)
        if p.exists():
            print(f"cast ledger: warning: overwriting existing file {out_file}", file=sys.stderr)
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(out_file, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        print(text)


# ── Argument parsing ──────────────────────────────────────────────────────────

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="cast-ledger",
        description="Render a signed per-session audit receipt from cast.db.",
    )
    p.add_argument("session_id", nargs="?", default=None, help="Session ID to render")
    p.add_argument("--last", type=int, metavar="N", help="Render the N most-recent sessions")
    p.add_argument("--since", metavar="YYYY-MM-DD", help="Render all sessions since this date")
    p.add_argument("--json", dest="as_json", action="store_true", help="Emit JSON output")
    p.add_argument("--out", metavar="FILE", help="Write output to FILE instead of stdout")
    p.add_argument("--verify", metavar="FILE", help="Verify a previously-written receipt file")
    p.add_argument("--db", metavar="PATH", help="Override DB path")
    return p


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    db_path = _get_db_path(args.db or "")

    # Verify mode
    if args.verify:
        try:
            conn = _connect(db_path)
        except Exception as e:
            print(f"cast ledger: cannot connect to db: {e}", file=sys.stderr)
            return 1
        return _cmd_verify(args.verify, conn)

    try:
        conn = _connect(db_path)
    except Exception as e:
        print(f"cast ledger: cannot connect to db: {e}", file=sys.stderr)
        return 1

    # Determine which sessions to render
    session_rows: List[sqlite3.Row] = []

    if args.last is not None:
        session_rows = _fetch_last_n_sessions(conn, args.last)
        if not session_rows:
            print("cast ledger: no sessions found in cast.db", file=sys.stderr)
            return 1

    elif args.since is not None:
        session_rows = _fetch_sessions_since(conn, args.since)
        if not session_rows:
            print(f"cast ledger: no sessions found since {args.since}", file=sys.stderr)
            return 1

    elif args.session_id is not None:
        row = _fetch_session(conn, args.session_id)
        if row is None:
            print(f"cast ledger: no such session: {args.session_id}", file=sys.stderr)
            return 1
        session_rows = [row]

    else:
        # Default: most-recent session
        row = _fetch_most_recent_session(conn)
        if row is None:
            print("cast ledger: no sessions found in cast.db", file=sys.stderr)
            return 1
        session_rows = [row]

    # Render
    if len(session_rows) == 1:
        rendered, _ = _render_session(conn, session_rows[0], args.as_json)
        _output(rendered, args.out)
    else:
        if args.as_json:
            # JSON array
            items = []
            for row in session_rows:
                _, obj = _render_session(conn, row, True)
                items.append(obj)
            rendered = json.dumps(items, sort_keys=True, indent=2, default=str)
            _output(rendered, args.out)
        else:
            # Markdown: separate with ---
            parts = []
            for row in session_rows:
                rendered, _ = _render_session(conn, row, False)
                parts.append(rendered)
            _output("\n---\n".join(parts), args.out)

    return 0


if __name__ == "__main__":
    sys.exit(main())
