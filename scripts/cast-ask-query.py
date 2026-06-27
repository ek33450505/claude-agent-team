#!/usr/bin/env python3
"""cast-ask-query.py — parametrized FTS5 search backend for `cast ask`.

Args: "<query>" [--kind K] [--since YYYY-MM-DD] [--limit N] [--db PATH]
Output: JSON array of {kind, ref_id, ts, title, snippet} to stdout.

On degraded/FTS5-unavailable path: JSON {"degraded": true, "rows": []}.
On no results: [].
Never crashes.
"""
import importlib.util
import json
import os
import re
import sqlite3
import sys
from pathlib import Path


# ── Embed module loader ──────────────────────────────────────────────────────

def _load_embed_module():
    """Lazy-load cast-memory-embed.py (hyphenated filename → importlib). Returns module or None on any failure (fail-open)."""
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cast-memory-embed.py')
        spec = importlib.util.spec_from_file_location('cast_memory_embed', path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


SEMANTIC_CANDIDATE_FLOOR = 50  # re-rank at least this many FTS hits when --semantic


# ── DB path resolution (mirrors cast_db._get_db_path) ───────────────────────

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
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA busy_timeout=5000;")
        conn.execute("PRAGMA journal_mode=WAL;")
    except Exception:
        pass
    return conn


# ── FTS5 query sanitization ──────────────────────────────────────────────────

def _sanitize_query(raw: str) -> str:
    """Convert raw user input into safe FTS5 double-quoted terms joined with AND.

    Consistent with FTS5's raw implicit-AND default; precision over recall for an
    audit tool. A document must contain ALL tokens to match.
    Example: 'cast-push' -> '"cast" AND "push"'
    Any characters outside word boundaries are stripped; each word is double-quoted.
    """
    tokens = re.findall(r'\w+', raw)
    if not tokens:
        return '""'
    return " AND ".join(f'"{t}"' for t in tokens)


# ── Core search ─────────────────────────────────────────────────────────────

def _build_sql_and_params(
    fts_query: str,
    kind: str,
    since: str,
    limit: int,
) -> tuple:
    """Build parameterized SQL + bound params list. Returns (sql, params)."""
    sql = (
        "SELECT kind, ref_id, ts, title, "
        "snippet(record_fts, 4, '[', ']', '…', 12) AS snippet "
        "FROM record_fts "
        "WHERE record_fts MATCH ?"
    )
    params: list = [fts_query]

    if kind:
        sql += " AND kind = ?"
        params.append(kind)
    if since:
        sql += " AND ts >= ?"
        params.append(since)

    sql += " ORDER BY rank LIMIT ?"
    params.append(limit)
    return sql, params


def _semantic_rerank(conn, rows, query, limit):
    """Cosine re-rank FTS candidate rows by similarity to the query embedding.

    Returns a re-ordered list (length<=limit) on success, or None to signal fail-open
    (caller then keeps pure FTS order). Fail-open triggers: no embeddings yet, Ollama down,
    module missing, or any exception. One Ollama call total (embeds the query, not the corpus).
    """
    try:
        cur = conn.execute("SELECT count(*) AS n FROM record_embed")
        r0 = cur.fetchone()
        if not r0 or (r0["n"] or 0) == 0:
            return None  # no embeddings → skip the Ollama round-trip entirely
        cme = _load_embed_module()
        if cme is None:
            return None
        qvec = cme.embed_text(query)
        if qvec is None:
            return None  # Ollama unreachable → fail-open
        scored = []
        for r in rows:
            er = conn.execute(
                "SELECT vec FROM record_embed WHERE kind = ? AND ref_id = ?",
                (r.get("kind"), r.get("ref_id")),
            ).fetchone()
            if er is None or er["vec"] is None:
                score = -1.0  # no embedding for this hit → sinks below scored ones (stable sort keeps FTS order among ties)
            else:
                score = cme.cosine_similarity(qvec, cme.unpack_embedding(er["vec"]))
            scored.append((score, r))
        scored.sort(key=lambda t: t[0], reverse=True)  # Python sort is stable → FTS rank order preserved within equal scores
        return [r for _, r in scored[:limit]]
    except Exception:
        return None


def search(
    query: str,
    kind: str = "",
    since: str = "",
    limit: int = 10,
    db_path: str = "",
    semantic: bool = False,
) -> dict:
    """Return {"rows": [...]} or {"degraded": True, "rows": []} on error."""
    # Guard invalid limits: <=0 (and the non-int default handled in main()) fall back to the default.
    if limit <= 0:
        limit = 10
    path = _get_db_path(db_path)
    try:
        conn = _connect(path)
    except Exception as e:
        return {"degraded": True, "rows": [], "note": f"DB connect failed: {e}"}

    # When semantic re-rank is requested, fetch a larger candidate pool then re-rank+slice.
    fetch_limit = max(limit, SEMANTIC_CANDIDATE_FLOOR) if semantic else limit

    def _execute(fts_query: str) -> list:
        sql, params = _build_sql_and_params(fts_query, kind, since, fetch_limit)
        cur = conn.execute(sql, params)
        return [dict(r) for r in cur.fetchall()]

    # First attempt: raw query
    try:
        rows = _execute(query)
        if semantic and rows:
            reranked = _semantic_rerank(conn, rows, query, limit)
            rows = reranked if reranked is not None else rows[:limit]
        else:
            rows = rows[:limit]
        conn.close()
        return {"rows": rows}
    except sqlite3.OperationalError as first_err:
        err_str = str(first_err).lower()

        # Degraded path: record_fts table absent (FTS5 not compiled in)
        if "no such table: record_fts" in err_str:
            try:
                conn.close()
            except Exception:
                pass
            return {
                "degraded": True,
                "rows": [],
                "note": "record_fts unavailable — FTS5 not supported in this sqlite build",
            }

        # FTS5 syntax error — retry with sanitized double-quoted terms
        sanitized = _sanitize_query(query)
        try:
            rows = _execute(sanitized)
            if semantic and rows:
                reranked = _semantic_rerank(conn, rows, query, limit)
                rows = reranked if reranked is not None else rows[:limit]
            else:
                rows = rows[:limit]
            conn.close()
            return {"rows": rows}
        except sqlite3.OperationalError as second_err:
            try:
                conn.close()
            except Exception:
                pass
            return {
                "degraded": False,
                "rows": [],
                "note": f"FTS5 query failed after sanitization: {second_err}",
            }
    except Exception as e:
        try:
            conn.close()
        except Exception:
            pass
        return {"degraded": True, "rows": [], "note": f"Unexpected error: {e}"}


# ── CLI ──────────────────────────────────────────────────────────────────────

def main() -> None:
    args = sys.argv[1:]
    query = ""
    kind = ""
    since = ""
    limit = 10
    db_path = ""
    semantic = False

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--kind" and i + 1 < len(args):
            kind = args[i + 1]
            i += 2
        elif a == "--since" and i + 1 < len(args):
            since = args[i + 1]
            i += 2
        elif a == "--limit" and i + 1 < len(args):
            try:
                limit = int(args[i + 1])
            except ValueError:
                limit = 10
            i += 2
        elif a == "--db" and i + 1 < len(args):
            db_path = args[i + 1]
            i += 2
        elif a == "--semantic":
            semantic = True
            i += 1
        elif not a.startswith("--"):
            query = a
            i += 1
        else:
            i += 1

    if not query:
        print(json.dumps([]), flush=True)
        sys.exit(0)

    result = search(query, kind=kind, since=since, limit=limit, db_path=db_path, semantic=semantic)

    # degraded → emit the full object so the caller can print an advisory
    if result.get("degraded"):
        print(json.dumps(result), flush=True)
    else:
        print(json.dumps(result.get("rows", [])), flush=True)


if __name__ == "__main__":
    main()
