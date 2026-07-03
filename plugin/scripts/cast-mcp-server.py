#!/usr/bin/env python3
"""cast-mcp-server.py — Read-only MCP stdio server over cast.db (v9 F4).

Serves 5 curated tools and 5 resources via JSON-RPC 2.0 / MCP 2025-06-18.

Security posture:
  - cast.db opened strictly read-only via URI mode=ro (write attempts fail at
    driver level, not by convention — Anthropic's sqlite MCP was archived over
    a SQL injection hole; we will not repeat it).
  - All queries use parameterized placeholders — no f-string interpolation of
    user arguments into SQL.
  - No arbitrary-SQL tool exposed.
  - limit clamped to 1..200 on every tool call.

Transport: stdio, newline-delimited JSON-RPC 2.0.
Protocol version: 2025-06-18.
"""

import sys
import os
import json
import sqlite3
import datetime
import contextlib
from pathlib import Path
from typing import Optional, Any

# ---------------------------------------------------------------------------
# sys.path — allow `import cast_db` from any working directory
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SERVER_VERSION: str = "1.0.0"
PROTOCOL_VERSION: str = "2025-06-18"


# ---------------------------------------------------------------------------
# Logging — fail-safe file appender, never raises
# ---------------------------------------------------------------------------
def _log(msg: str, level: str = "INFO") -> None:
    """Append a timestamped entry to ~/.claude/logs/mcp-server.log."""
    try:
        log_path = Path.home() / ".claude" / "logs" / "mcp-server.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(str(log_path), "a") as fh:
            fh.write(f"[{ts}] {level} cast-mcp-server: {msg}\n")
    except Exception:
        pass  # Never crash — logging failure is silent


# ---------------------------------------------------------------------------
# DB helpers — read-only, parameterized
# ---------------------------------------------------------------------------
def _ro_connect() -> sqlite3.Connection:
    """Open cast.db strictly read-only via URI. Raises OperationalError if absent."""
    db_path = os.environ.get("CAST_DB_PATH", str(Path.home() / ".claude" / "cast.db"))
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def _clamp_limit(val: Any, default: int = 10) -> int:
    """Clamp a user-supplied limit to the range [1, 200]."""
    try:
        n = int(val)
    except (TypeError, ValueError):
        n = default
    return max(1, min(200, n))


def _rows_to_text(rows: list) -> str:
    """Format a list of row dicts as a header + compact JSON array."""
    n = len(rows)
    header = f"{n} row{'s' if n != 1 else ''}"
    return f"{header}\n{json.dumps(rows, default=str)}"


def _is_error_text(text: str) -> bool:
    """Heuristic: success texts always start with a digit (row count); errors start with a letter."""
    return not (text and text[0].isdigit())


# ---------------------------------------------------------------------------
# Tool implementations — return plain text strings
# ---------------------------------------------------------------------------
def _fetch_decisions(limit: int) -> str:
    try:
        with contextlib.closing(_ro_connect()) as conn:
            cursor = conn.execute(
                "SELECT id, session_id, prompt_snippet, chosen_agent, model, "
                "created_at, outcome "
                "FROM dispatch_decisions ORDER BY id DESC LIMIT ?",
                (limit,),
            )
            rows = [dict(r) for r in cursor.fetchall()]
        return _rows_to_text(rows)
    except sqlite3.OperationalError as e:
        _log(f"fetch_decisions OperationalError: {e}", level="WARN")
        return f"cast.db unavailable or table missing: {e}"
    except Exception as e:
        _log(f"fetch_decisions error: {e}")
        return f"Error querying dispatch_decisions: {e}"


def _fetch_incidents(limit: int, query: str = "") -> str:
    try:
        with contextlib.closing(_ro_connect()) as conn:
            base_cols = (
                "id, occurred_at, problem_summary, fix_summary, related_files, "
                "related_commit, resolution_status, surfaced_by"
            )
            if query:
                # Escape LIKE metacharacters so a literal % or _ matches literally (and can't
                # broaden to a full scan). ESCAPE '\' activates the backslash escapes below.
                esc = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                like = f"%{esc}%"
                cursor = conn.execute(
                    f"SELECT {base_cols} FROM incidents "
                    "WHERE problem_summary LIKE ? ESCAPE '\\' OR fix_summary LIKE ? ESCAPE '\\' "
                    "ORDER BY occurred_at DESC LIMIT ?",
                    (like, like, limit),
                )
            else:
                cursor = conn.execute(
                    f"SELECT {base_cols} FROM incidents "
                    "ORDER BY occurred_at DESC LIMIT ?",
                    (limit,),
                )
            rows = [dict(r) for r in cursor.fetchall()]
        return _rows_to_text(rows)
    except sqlite3.OperationalError as e:
        _log(f"fetch_incidents OperationalError: {e}", level="WARN")
        return f"cast.db unavailable or table missing: {e}"
    except Exception as e:
        _log(f"fetch_incidents error: {e}")
        return f"Error querying incidents: {e}"


def _fetch_cost(by: str, limit: int) -> str:
    try:
        with contextlib.closing(_ro_connect()) as conn:
            if by == "session":
                cursor = conn.execute(
                    "SELECT session_id, COALESCE(SUM(cost_usd),0) AS cost_usd, "
                    "COUNT(*) AS runs FROM agent_runs "
                    "GROUP BY session_id ORDER BY cost_usd DESC LIMIT ?",
                    (limit,),
                )
            elif by == "branch":
                # branch is canonical since F1 (cast-db-init.sh CREATE TABLE agent_runs),
                # but absent on DBs predating it — PRAGMA-guard before querying.
                pragma = conn.execute("PRAGMA table_info(agent_runs)").fetchall()
                cols = {row["name"] for row in pragma}
                if "branch" not in cols:
                    return "branch attribution unavailable on this DB (column absent from schema)"
                cursor = conn.execute(
                    "SELECT COALESCE(branch,'(none)') AS branch, "
                    "COALESCE(SUM(cost_usd),0) AS cost_usd, COUNT(*) AS runs "
                    "FROM agent_runs GROUP BY branch ORDER BY cost_usd DESC LIMIT ?",
                    (limit,),
                )
            else:  # by == "agent" (default)
                cursor = conn.execute(
                    "SELECT agent, COALESCE(SUM(cost_usd),0) AS cost_usd, "
                    "COUNT(*) AS runs FROM agent_runs "
                    "GROUP BY agent ORDER BY cost_usd DESC LIMIT ?",
                    (limit,),
                )
            rows = [dict(r) for r in cursor.fetchall()]
        return _rows_to_text(rows)
    except sqlite3.OperationalError as e:
        _log(f"fetch_cost OperationalError: {e}", level="WARN")
        return f"cast.db unavailable or table missing: {e}"
    except Exception as e:
        _log(f"fetch_cost error: {e}")
        return f"Error querying cost: {e}"


def _fetch_sessions(limit: int) -> str:
    try:
        with contextlib.closing(_ro_connect()) as conn:
            # Canonical sessions columns only (cast-db-init.sh is the single source of truth).
            # total_input_tokens/total_output_tokens/total_cost_usd/model were dropped from the
            # canonical schema in migration 022 and are absent on fresh installs; per-session cost
            # is served by cast_cost(by=session), which reads agent_runs (the canonical cost source).
            cursor = conn.execute(
                "SELECT id, project, project_root, started_at, ended_at, status "
                "FROM sessions WHERE deleted_at IS NULL "
                "ORDER BY started_at DESC LIMIT ?",
                (limit,),
            )
            rows = [dict(r) for r in cursor.fetchall()]
        return _rows_to_text(rows)
    except sqlite3.OperationalError as e:
        _log(f"fetch_sessions OperationalError: {e}", level="WARN")
        return f"cast.db unavailable or table missing: {e}"
    except Exception as e:
        _log(f"fetch_sessions error: {e}")
        return f"Error querying sessions: {e}"


def _sanitize_fts5_query(raw: str) -> str:
    """Wrap each whitespace-token in double-quotes for FTS5 safety.

    e.g. 'cast push' → '"cast" AND "push"'
    Prevents FTS5 from choking on bare special characters.
    """
    tokens = raw.split()
    if not tokens:
        return '""'
    # FTS5 phrase-escapes a double-quote by doubling it ("" -> literal "). Escape embedded
    # quotes so foo"bar becomes the literal phrase "foo""bar" rather than malformed syntax.
    return " AND ".join('"' + t.replace('"', '""') + '"' for t in tokens)


def _fetch_ask(raw_query: str, limit: int) -> str:
    fts_query = _sanitize_fts5_query(raw_query)
    try:
        with contextlib.closing(_ro_connect()) as conn:
            cursor = conn.execute(
                "SELECT kind, ref_id, ts, title, "
                "snippet(record_fts, 4, '[', ']', '…', 12) AS snippet, "
                "agent, mtype FROM record_fts "
                "WHERE record_fts MATCH ? ORDER BY rank LIMIT ?",
                (fts_query, limit),
            )
            rows = [dict(r) for r in cursor.fetchall()]
        return _rows_to_text(rows)
    except sqlite3.OperationalError as e:
        err = str(e)
        if "no such table" in err:
            return "full-text index unavailable (record_fts table absent)"
        _log(f"fetch_ask OperationalError: {e}", level="WARN")
        return f"cast.db unavailable or FTS error: {e}"
    except Exception as e:
        _log(f"fetch_ask error: {e}")
        return f"Error querying FTS: {e}"


# ---------------------------------------------------------------------------
# Tool dispatch wrappers
# ---------------------------------------------------------------------------
def _tool_cast_decisions(args: dict) -> str:
    return _fetch_decisions(_clamp_limit(args.get("limit", 10)))


def _tool_cast_incidents(args: dict) -> str:
    return _fetch_incidents(
        _clamp_limit(args.get("limit", 10)),
        str(args.get("query", "")).strip(),
    )


def _tool_cast_cost(args: dict) -> str:
    by = args.get("by", "agent")
    if by not in ("agent", "branch", "session"):
        by = "agent"
    return _fetch_cost(by, _clamp_limit(args.get("limit", 10)))


def _tool_cast_sessions(args: dict) -> str:
    return _fetch_sessions(_clamp_limit(args.get("limit", 10)))


def _tool_cast_ask(args: dict) -> str:
    raw = str(args.get("query", "")).strip()
    if not raw:
        return "query argument is required"
    return _fetch_ask(raw, _clamp_limit(args.get("limit", 10)))


_TOOL_DISPATCH = {
    "cast_decisions": _tool_cast_decisions,
    "cast_incidents": _tool_cast_incidents,
    "cast_cost": _tool_cast_cost,
    "cast_sessions": _tool_cast_sessions,
    "cast_ask": _tool_cast_ask,
}

# ---------------------------------------------------------------------------
# Resource helpers
# ---------------------------------------------------------------------------
_EXPOSED_TABLES = [
    "dispatch_decisions",
    "incidents",
    "agent_runs",
    "sessions",
    "record_fts",
]


def _resource_schema() -> str:
    """Return a text overview: exposed tables and their current row counts."""
    lines = ["cast.db exposed tables and row counts:"]
    try:
        with contextlib.closing(_ro_connect()) as conn:
            for t in _EXPOSED_TABLES:
                try:
                    # Table names are hardcoded literals — not user input — so f-string is safe here.
                    row = conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()  # noqa: S608
                    lines.append(f"  {t}: {row[0]} rows")
                except sqlite3.OperationalError:
                    lines.append(f"  {t}: unavailable")
    except sqlite3.OperationalError as e:
        return f"cast.db unavailable: {e}"
    return "\n".join(lines)


RESOURCE_DEFS = [
    {
        "uri": "cast://schema",
        "name": "CAST Schema Overview",
        "description": "Exposed tables and row counts (read-only)",
        "mimeType": "text/plain",
    },
    {
        "uri": "cast://decisions/recent",
        "name": "Recent Dispatch Decisions",
        "description": "Last 10 agent-routing decisions (read-only)",
        "mimeType": "text/plain",
    },
    {
        "uri": "cast://incidents/recent",
        "name": "Recent Incidents",
        "description": "Last 10 recorded incidents (read-only)",
        "mimeType": "text/plain",
    },
    {
        "uri": "cast://cost/summary",
        "name": "Cost Summary by Agent",
        "description": "Token/$ aggregation by agent, top 10 (read-only)",
        "mimeType": "text/plain",
    },
    {
        "uri": "cast://sessions/recent",
        "name": "Recent Sessions",
        "description": "Last 10 CAST sessions (read-only)",
        "mimeType": "text/plain",
    },
]


def _read_resource(uri: str) -> Optional[str]:
    """Return text for a known resource URI, or None for unknown."""
    if uri == "cast://schema":
        return _resource_schema()
    if uri == "cast://decisions/recent":
        return _fetch_decisions(10)
    if uri == "cast://incidents/recent":
        return _fetch_incidents(10)
    if uri == "cast://cost/summary":
        return _fetch_cost("agent", 10)
    if uri == "cast://sessions/recent":
        return _fetch_sessions(10)
    return None


# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------
TOOL_DEFS = [
    {
        "name": "cast_decisions",
        "description": "Recent agent-dispatch routing decisions from cast.db (read-only).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Max rows to return (1–200, default 10)"},
            },
            "required": [],
        },
    },
    {
        "name": "cast_incidents",
        "description": "Past incident log — error class and fix summaries from cast.db (read-only).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Max rows to return (1–200, default 10)"},
                "query": {"type": "string", "description": "Optional keyword filter on problem/fix summary"},
            },
            "required": [],
        },
    },
    {
        "name": "cast_cost",
        "description": "Token and USD cost aggregation from agent_runs in cast.db (read-only).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "by": {
                    "type": "string",
                    "enum": ["agent", "branch", "session"],
                    "description": "Grouping dimension (default: agent)",
                },
                "limit": {"type": "integer", "description": "Max rows to return (1–200, default 10)"},
            },
            "required": [],
        },
    },
    {
        "name": "cast_sessions",
        "description": "Recent CAST sessions (id, project, project_root, started_at, ended_at, status) from cast.db (read-only). For per-session cost, use cast_cost with by=session.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Max rows to return (1–200, default 10)"},
            },
            "required": [],
        },
    },
    {
        "name": "cast_ask",
        "description": "FTS5 full-text search over the entire CAST record in cast.db (read-only).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query (required)"},
                "limit": {"type": "integer", "description": "Max rows to return (1–200, default 10)"},
            },
            "required": ["query"],
        },
    },
]

# ---------------------------------------------------------------------------
# JSON-RPC 2.0 envelope helpers
# ---------------------------------------------------------------------------
def _ok(msg_id: Any, result: dict) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _err(msg_id: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def _tool_result(text: str, is_error: bool = False) -> dict:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


# ---------------------------------------------------------------------------
# Request dispatcher
# ---------------------------------------------------------------------------
def handle(msg: dict) -> Optional[dict]:
    """Dispatch a JSON-RPC message. Returns a response dict or None (notifications)."""
    method = msg.get("method", "")

    # Notifications have no "id" key — return None (no response written)
    if "id" not in msg:
        return None

    msg_id = msg["id"]

    if method == "initialize":
        params = msg.get("params") or {}
        client_version = params.get("protocolVersion")
        # Echo client version if server supports it; fall back to server's version.
        negotiated_version = client_version if client_version == PROTOCOL_VERSION else PROTOCOL_VERSION
        return _ok(
            msg_id,
            {
                "protocolVersion": negotiated_version,
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": "cast-record", "version": SERVER_VERSION},
            },
        )

    if method == "ping":
        return _ok(msg_id, {})

    if method == "tools/list":
        return _ok(msg_id, {"tools": TOOL_DEFS})

    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name", "")
        arguments = params.get("arguments") or {}
        fn = _TOOL_DISPATCH.get(name)
        if fn is None:
            return _err(msg_id, -32602, f"Unknown tool: {name}")
        try:
            text = fn(arguments)
            is_error = _is_error_text(text)
            return _ok(msg_id, _tool_result(text, is_error=is_error))
        except Exception as e:
            _log(f"tools/call {name} unhandled exception: {e}")
            return _ok(msg_id, _tool_result(f"Internal error: {e}", is_error=True))

    if method == "resources/list":
        return _ok(msg_id, {"resources": RESOURCE_DEFS})

    if method == "resources/read":
        params = msg.get("params") or {}
        uri = params.get("uri", "")
        text = _read_resource(uri)
        if text is None:
            return _err(msg_id, -32602, f"Unknown resource: {uri}")
        return _ok(
            msg_id,
            {"contents": [{"uri": uri, "mimeType": "text/plain", "text": text}]},
        )

    # Unknown method (has id) → error
    return _err(msg_id, -32601, f"Method not found: {method}")


# ---------------------------------------------------------------------------
# Serve loop — reads newline-delimited JSON-RPC from stdin, writes to stdout
# ---------------------------------------------------------------------------
def main() -> None:
    _log(f"starting (version {SERVER_VERSION}, protocol {PROTOCOL_VERSION})")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        if len(line) > 1_048_576:  # 1 MB cap — guard json.loads against memory exhaustion
            resp = _err(None, -32700, "Request line too large")
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
            continue
        # Per-message try/except: one bad frame logs and continues, never kills the loop
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            resp = _err(None, -32700, f"Parse error: {e}")
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
            continue
        try:
            resp = handle(msg)
        except Exception as e:
            _log(f"handle() unhandled exception: {e}")
            resp = _err(msg.get("id"), -32603, f"Internal error: {e}")
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
    _log("EOF — exiting")


if __name__ == "__main__":
    main()
