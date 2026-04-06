#!/usr/bin/env python3
"""
cast-mcp-memory-server.py — MCP server exposing CAST agent_memories as tools.

A long-running stdio MCP server using the mcp Python SDK. Exposes four tools:
  - memory_search: FTS5 + optional cosine re-rank retrieval
  - memory_write: Insert/upsert memories to shared pool
  - memory_validate: Age-based staleness check
  - memory_list: Raw listing by agent, sorted by importance

Graceful degradation:
  - If cast.db not found: tools return {"error": "cast.db not found"}
  - If Ollama unavailable: memory_search falls back to FTS5-only

Requires: pip install mcp
"""

import os
import sys
import json
import math
import re
import struct
import sqlite3
from datetime import datetime, timedelta, timezone

# --- DB path resolution ---

def get_db_path():
    """Resolve cast.db path."""
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def get_connection():
    """Return (conn, error_msg). If error, conn is None."""
    db_path = get_db_path()
    if not os.path.exists(db_path):
        return None, "cast.db not found"
    try:
        conn = sqlite3.connect(db_path, timeout=10)
        # Check agent_memories exists
        check = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'"
        ).fetchone()
        if not check:
            conn.close()
            return None, "agent_memories table not found"
        return conn, None
    except sqlite3.Error as e:
        return None, f"DB connection error: {e}"


# --- Copied from cast-memory-router.py (no cross-script imports) ---

OLLAMA_EMBED_URL = 'http://localhost:11434/api/embed'
EMBED_MODEL = 'nomic-embed-text'

VALID_TYPES = {'user', 'feedback', 'project', 'reference', 'procedural'}


def embed_text(text, timeout=3):
    """Call Ollama embed API. Returns list[float] or None on any error."""
    try:
        import urllib.request
        payload = json.dumps({"model": EMBED_MODEL, "input": text}).encode('utf-8')
        req = urllib.request.Request(
            OLLAMA_EMBED_URL,
            data=payload,
            headers={'Content-Type': 'application/json'},
            method='POST'
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode('utf-8'))
        embeddings = data.get('embeddings')
        if not embeddings or not isinstance(embeddings, list) or len(embeddings) == 0:
            return None
        vec = embeddings[0]
        if not isinstance(vec, list) or len(vec) == 0:
            return None
        return [float(x) for x in vec]
    except Exception:
        return None


def unpack_embedding(blob):
    """Unpack float32 BLOB to list of floats."""
    return list(struct.unpack(f'{len(blob)//4}f', blob))


def cosine_similarity(a, b):
    """Dot product / (norm_a * norm_b). Returns 0.0 if either norm is zero."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


def sanitize_fts_query(prompt):
    """Sanitize prompt for FTS5 MATCH to avoid syntax errors."""
    sanitized = re.sub(r'["\*\^\(\)]+', ' ', prompt)
    sanitized = re.sub(r'\b(AND|OR|NOT)\b', ' ', sanitized)
    sanitized = ' '.join(sanitized.split())
    return sanitized if sanitized.strip() else None


def relevance_score(mem_row, fts_rank, column_names, cosine_sim=0.0):
    """Weighted score: 0.3*recency + 0.2*importance + 0.25*fts_rank_norm + 0.25*cosine_sim"""
    created_at_str = mem_row[column_names.index('created_at')] if 'created_at' in column_names else None
    if created_at_str:
        try:
            created_at = datetime.fromisoformat(created_at_str.replace('Z', '+00:00'))
            age_hours = (datetime.now(timezone.utc) - created_at).total_seconds() / 3600
        except Exception:
            age_hours = 720
    else:
        age_hours = 720

    decay = mem_row[column_names.index('decay_rate')] if 'decay_rate' in column_names else 0.995
    if decay is None:
        decay = 0.995
    recency = math.exp(-decay * age_hours / 8760)

    importance = mem_row[column_names.index('importance')] if 'importance' in column_names else 0.5
    if importance is None:
        importance = 0.5

    fts_norm = max(0.0, min(1.0, 1.0 + fts_rank / 10.0)) if fts_rank != 0.0 else 0.5

    return 0.3 * recency + 0.2 * importance + 0.25 * fts_norm + 0.25 * cosine_sim


def retrieve_memories(conn, prompt, agent, top_n=5, type_filter=None):
    """Return top-N memories for agent, ranked by relevance. Includes shared pool."""
    has_fts = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'"
    ).fetchone() is not None

    cursor = conn.execute("PRAGMA table_info(agent_memories)")
    column_names = [row[1] for row in cursor.fetchall()]

    type_clause = "AND am.type = ?" if type_filter else ""
    type_params = (type_filter,) if type_filter else ()

    rows = []

    if has_fts:
        safe_prompt = sanitize_fts_query(prompt)
        if safe_prompt:
            try:
                sql = f"""
                    SELECT am.*, fts.rank
                    FROM agent_memories am
                    JOIN agent_memories_fts fts ON am.id = fts.rowid
                    WHERE agent_memories_fts MATCH ?
                    AND (am.agent = ? OR am.agent = 'shared')
                    {type_clause}
                    ORDER BY fts.rank
                    LIMIT 50
                """
                params = (safe_prompt, agent) + type_params
                rows = conn.execute(sql, params).fetchall()
            except sqlite3.OperationalError:
                rows = []

    if not rows:
        sql = f"""
            SELECT am.*, 0 AS rank
            FROM agent_memories am
            WHERE (am.agent = ? OR am.agent = 'shared')
            {type_clause}
        """
        params = (agent,) + type_params
        rows = conn.execute(sql, params).fetchall()

    col_names_with_rank = column_names + ['rank']

    # Attempt cosine re-rank with 3s timeout
    query_embedding = embed_text(prompt, timeout=3)

    scored = []
    for row in rows:
        row_list = list(row)
        fts_rank = row_list[-1] if row_list else 0.0
        if fts_rank is None:
            fts_rank = 0.0

        cosine_sim = 0.0
        if query_embedding is not None and 'embedding' in col_names_with_rank:
            embed_idx = col_names_with_rank.index('embedding')
            stored_blob = row_list[embed_idx] if embed_idx < len(row_list) else None
            if stored_blob:
                try:
                    stored_vec = unpack_embedding(stored_blob)
                    cosine_sim = cosine_similarity(query_embedding, stored_vec)
                except Exception:
                    cosine_sim = 0.0

        score = relevance_score(row_list, fts_rank, col_names_with_rank, cosine_sim=cosine_sim)
        scored.append((score, row_list, column_names))

    scored.sort(key=lambda x: x[0], reverse=True)
    return scored[:top_n]


def write_shared_memory(conn, name, description, content, memory_type='project',
                        importance=0.5, agent='shared'):
    """Write a memory to the pool."""
    try:
        conn.execute("""
            INSERT INTO agent_memories (agent, type, name, description, content, importance)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(agent, name) DO UPDATE SET
                content=excluded.content,
                description=excluded.description,
                importance=excluded.importance,
                updated_at=CURRENT_TIMESTAMP
        """, (agent, memory_type, name, description, content, importance))
    except sqlite3.OperationalError:
        conn.execute("""
            INSERT OR REPLACE INTO agent_memories
            (agent, type, name, description, content, importance)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (agent, memory_type, name, description, content, importance))
    conn.commit()


# --- MCP Server ---

try:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    import mcp.types as types
except ImportError:
    print("ERROR: mcp package not installed. Run: pip install mcp", file=sys.stderr)
    sys.exit(1)

server = Server("cast-memory")


@server.list_tools()
async def list_tools():
    return [
        types.Tool(
            name="memory_search",
            description="Search CAST agent memories using FTS5 and optional cosine similarity re-ranking.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query text"},
                    "agent": {"type": "string", "description": "Agent name (default: shared)", "default": "shared"},
                    "type": {"type": "string", "description": "Filter by memory type (optional)"},
                    "top_n": {"type": "integer", "description": "Max results (default: 5)", "default": 5},
                },
                "required": ["query"],
            },
        ),
        types.Tool(
            name="memory_write",
            description="Write or update a memory in the CAST agent memory system.",
            inputSchema={
                "type": "object",
                "properties": {
                    "agent": {"type": "string", "description": "Agent name (default: shared)", "default": "shared"},
                    "type": {"type": "string", "description": "Memory type (user, feedback, project, reference, procedural)"},
                    "name": {"type": "string", "description": "Unique memory name"},
                    "description": {"type": "string", "description": "Short description"},
                    "content": {"type": "string", "description": "Full memory content"},
                    "importance": {"type": "number", "description": "Importance score 0.0-1.0 (default: 0.5)", "default": 0.5},
                },
                "required": ["type", "name", "description", "content"],
            },
        ),
        types.Tool(
            name="memory_validate",
            description="Check CAST agent memories for staleness based on age.",
            inputSchema={
                "type": "object",
                "properties": {
                    "agent": {"type": "string", "description": "Agent name (optional, checks all if omitted)"},
                    "age_days": {"type": "integer", "description": "Age threshold in days (default: 30)", "default": 30},
                },
            },
        ),
        types.Tool(
            name="memory_list",
            description="List CAST agent memories sorted by importance.",
            inputSchema={
                "type": "object",
                "properties": {
                    "agent": {"type": "string", "description": "Agent name"},
                    "type": {"type": "string", "description": "Filter by memory type (optional)"},
                    "limit": {"type": "integer", "description": "Max results (default: 20)", "default": 20},
                },
                "required": ["agent"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict):
    if name == "memory_search":
        return await handle_memory_search(arguments)
    elif name == "memory_write":
        return await handle_memory_write(arguments)
    elif name == "memory_validate":
        return await handle_memory_validate(arguments)
    elif name == "memory_list":
        return await handle_memory_list(arguments)
    else:
        return [types.TextContent(type="text", text=json.dumps({"error": f"Unknown tool: {name}"}))]


async def handle_memory_search(args):
    conn, err = get_connection()
    if err:
        return [types.TextContent(type="text", text=json.dumps({"error": err}))]

    try:
        query = args.get("query", "")
        agent = args.get("agent", "shared")
        type_filter = args.get("type")
        top_n = args.get("top_n", 5)

        results = retrieve_memories(conn, query, agent, top_n=top_n, type_filter=type_filter)

        output = []
        for score, row_list, col_names in results:
            mem_dict = {}
            for i, col in enumerate(col_names):
                if col == 'embedding':
                    continue  # Skip binary blob in output
                mem_dict[col] = row_list[i] if i < len(row_list) else None
            mem_dict['score'] = round(score, 4)
            output.append(mem_dict)

        conn.close()
        return [types.TextContent(type="text", text=json.dumps(output, default=str))]
    except Exception as e:
        try:
            conn.close()
        except Exception:
            pass
        return [types.TextContent(type="text", text=json.dumps({"error": str(e)}))]


async def handle_memory_write(args):
    conn, err = get_connection()
    if err:
        return [types.TextContent(type="text", text=json.dumps({"error": err}))]

    try:
        agent = args.get("agent", "shared")
        mem_type = args.get("type", "project")
        name = args.get("name", "")
        description = args.get("description", "")
        content = args.get("content", "")
        importance = args.get("importance", 0.5)

        write_shared_memory(conn, name, description, content,
                            memory_type=mem_type, importance=importance, agent=agent)
        conn.close()
        return [types.TextContent(type="text", text=json.dumps({"status": "ok", "name": name}))]
    except Exception as e:
        try:
            conn.close()
        except Exception:
            pass
        return [types.TextContent(type="text", text=json.dumps({"status": "error", "message": str(e)}))]


async def handle_memory_validate(args):
    conn, err = get_connection()
    if err:
        return [types.TextContent(type="text", text=json.dumps({"error": err}))]

    try:
        agent = args.get("agent")
        age_days = args.get("age_days", 30)
        now = datetime.now(timezone.utc)
        threshold = now - timedelta(days=age_days)

        # Get column info
        col_info = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
        col_names = [r[1] for r in col_info]
        has_validated = 'last_validated_at' in col_names

        # Build query
        where_clause = "WHERE agent = ?" if agent else ""
        params = (agent,) if agent else ()
        rows = conn.execute(f"SELECT * FROM agent_memories {where_clause}", params).fetchall()

        results = []
        for row in rows:
            mem = dict(zip(col_names, row))
            # Age check (same logic as cast-memory-validate.py check_age)
            staleness = 0.0
            recommendation = "keep"

            last_validated = mem.get('last_validated_at') if has_validated else None
            created_at_str = mem.get('created_at')

            check_date = None
            if last_validated:
                try:
                    check_date = datetime.fromisoformat(last_validated.replace('Z', '+00:00'))
                    if check_date.tzinfo is None:
                        check_date = check_date.replace(tzinfo=timezone.utc)
                except Exception:
                    check_date = None

            if check_date is None and created_at_str:
                try:
                    check_date = datetime.fromisoformat(created_at_str.replace('Z', '+00:00'))
                    if check_date.tzinfo is None:
                        check_date = check_date.replace(tzinfo=timezone.utc)
                except Exception:
                    check_date = None

            if check_date and check_date < threshold:
                days_ago = (now - check_date).days
                staleness = min(1.0, days_ago / (age_days * 2))
                if staleness >= 0.5:
                    recommendation = "archive"
                elif staleness >= 0.3:
                    recommendation = "review"

            results.append({
                "id": mem.get('id'),
                "name": mem.get('name', ''),
                "staleness_score": round(staleness, 4),
                "recommendation": recommendation,
            })

        conn.close()
        results.sort(key=lambda x: x['staleness_score'], reverse=True)
        return [types.TextContent(type="text", text=json.dumps(results, default=str))]
    except Exception as e:
        try:
            conn.close()
        except Exception:
            pass
        return [types.TextContent(type="text", text=json.dumps({"error": str(e)}))]


async def handle_memory_list(args):
    conn, err = get_connection()
    if err:
        return [types.TextContent(type="text", text=json.dumps({"error": err}))]

    try:
        agent = args.get("agent", "shared")
        type_filter = args.get("type")
        limit = args.get("limit", 20)

        # Get column names
        col_info = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
        col_names = [r[1] for r in col_info]

        type_clause = "AND type = ?" if type_filter else ""
        type_params = (type_filter,) if type_filter else ()

        sql = f"""
            SELECT * FROM agent_memories
            WHERE (agent = ? OR agent = 'shared')
            {type_clause}
            ORDER BY importance DESC
            LIMIT ?
        """
        params = (agent,) + type_params + (limit,)
        rows = conn.execute(sql, params).fetchall()

        output = []
        for row in rows:
            mem_dict = dict(zip(col_names, row))
            # Remove embedding blob from output
            mem_dict.pop('embedding', None)
            output.append(mem_dict)

        conn.close()
        return [types.TextContent(type="text", text=json.dumps(output, default=str))]
    except Exception as e:
        try:
            conn.close()
        except Exception:
            pass
        return [types.TextContent(type="text", text=json.dumps({"error": str(e)}))]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
