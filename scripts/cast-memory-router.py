#!/usr/bin/env python3
"""
cast-memory-router.py — FTS5-indexed, relevance-scored memory router for CAST agents.

Usage (route mode — default, backward compatible):
  cast-memory-router.py --prompt "<text>" [--db <path>] [--min-confidence 0.7]
  echo "text" | cast-memory-router.py

Usage (retrieve mode):
  cast-memory-router.py --mode retrieve --agent <name> --prompt "<text>" [--top-n 5] [--type <type>]

Output (route mode):
  {"agent": "debugger", "confidence": 0.82, "memory_id": 42, "reason": "..."}
  {"agent": null, "confidence": 0.0}

Output (retrieve mode):
  [{"score": 0.91, "agent": "shared", "type": "procedural", "name": "...", ...}, ...]
"""

import sys
import os
import json
import re
import math
import argparse
import sqlite3
import struct
from datetime import datetime, timezone

STOP_WORDS = {
    'a', 'an', 'the', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for',
    'of', 'with', 'by', 'from', 'is', 'are', 'was', 'were', 'be', 'been',
    'being', 'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would',
    'could', 'should', 'may', 'might', 'shall', 'can', 'need', 'dare',
    'ought', 'used', 'it', 'its', 'this', 'that', 'these', 'those', 'i',
    'me', 'my', 'we', 'our', 'you', 'your', 'he', 'she', 'they', 'them',
    'his', 'her', 'their', 'what', 'which', 'who', 'how', 'when', 'where',
    'why', 'all', 'any', 'both', 'each', 'few', 'more', 'most', 'other',
    'some', 'such', 'no', 'not', 'only', 'same', 'so', 'than', 'too',
    'very', 'just', 'also', 'as', 'up', 'if', 'then', 'into', 'about',
}

VALID_TYPES = {'user', 'feedback', 'project', 'reference', 'procedural'}

OLLAMA_EMBED_URL = 'http://localhost:11434/api/embed'
EMBED_MODEL = 'nomic-embed-text'


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


def tokenize(text):
    """Split on whitespace + punctuation, lowercase, remove stop words, filter short."""
    tokens = re.split(r'[\s\W]+', text.lower())
    return [t for t in tokens if len(t) >= 3 and t not in STOP_WORDS]


def relevance_score(mem_row, fts_rank, column_names, cosine_sim=0.0):
    """Weighted score: 0.3*recency + 0.2*importance + 0.25*fts_rank_norm + 0.25*cosine_sim"""
    # Recency
    created_at_str = mem_row[column_names.index('created_at')] if 'created_at' in column_names else None
    if created_at_str:
        try:
            created_at = datetime.fromisoformat(created_at_str.replace('Z', '+00:00'))
            age_hours = (datetime.now(timezone.utc) - created_at).total_seconds() / 3600
        except Exception:
            age_hours = 720  # default 30 days
    else:
        age_hours = 720

    decay = mem_row[column_names.index('decay_rate')] if 'decay_rate' in column_names else 0.995
    # Guard against None decay (rows inserted before schema migration)
    if decay is None:
        decay = 0.995
    recency = math.exp(-decay * age_hours / 8760)  # normalize: decay over 1 year horizon

    # Importance
    importance = mem_row[column_names.index('importance')] if 'importance' in column_names else 0.5
    if importance is None:
        importance = 0.5

    # FTS rank: sqlite FTS5 rank is negative (more negative = better match), normalize to 0-1
    # rank of 0.0 means no FTS match was used (fallback path)
    fts_norm = max(0.0, min(1.0, 1.0 + fts_rank / 10.0)) if fts_rank != 0.0 else 0.5

    return 0.3 * recency + 0.2 * importance + 0.25 * fts_norm + 0.25 * cosine_sim


def sanitize_fts_query(prompt):
    """Sanitize prompt for FTS5 MATCH to avoid syntax errors with special chars."""
    # Strip FTS5 special characters/operators that could cause parse errors
    # Remove: " * ^ ( ) OR AND NOT -
    sanitized = re.sub(r'["\*\^\(\)]+', ' ', prompt)
    # Remove bare FTS5 boolean operators as whole words
    sanitized = re.sub(r'\b(AND|OR|NOT)\b', ' ', sanitized)
    # Collapse whitespace
    sanitized = ' '.join(sanitized.split())
    return sanitized if sanitized.strip() else None


def retrieve_memories(conn, prompt, agent, top_n=5, type_filter=None):
    """Return top-N memories for agent, ranked by relevance. Includes shared pool."""
    # Check FTS availability
    has_fts = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'"
    ).fetchone() is not None

    # Get column names for flexible field access
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
                # FTS query failed — fall through to full scan
                rows = []

    if not rows:
        # Fallback: full table scan
        sql = f"""
            SELECT am.*, 0 AS rank
            FROM agent_memories am
            WHERE (am.agent = ? OR am.agent = 'shared')
            {type_clause}
        """
        params = (agent,) + type_params
        rows = conn.execute(sql, params).fetchall()

    # Build column_names + 'rank' for scoring
    col_names_with_rank = column_names + ['rank']

    # Attempt cosine re-rank
    query_embedding = embed_text(prompt)

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
        scored.append((score, row_list))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [(s, r) for s, r in scored[:top_n]]


def write_shared_memory(conn, name, description, content, memory_type='project',
                        importance=0.5, decay_rate=0.993):
    """Write a memory to the shared pool (agent='shared')."""
    if memory_type not in VALID_TYPES:
        raise ValueError(f"Invalid memory type: {memory_type}. Must be one of {VALID_TYPES}")

    # Check if UNIQUE constraint on (agent, name) exists by trying ON CONFLICT
    # If the constraint doesn't exist, this will fall back to a plain insert
    try:
        conn.execute("""
            INSERT INTO agent_memories (agent, type, name, description, content, importance, decay_rate)
            VALUES ('shared', ?, ?, ?, ?, ?, ?)
            ON CONFLICT(agent, name) DO UPDATE SET
                content=excluded.content,
                description=excluded.description,
                importance=excluded.importance,
                updated_at=CURRENT_TIMESTAMP
        """, (memory_type, name, description, content, importance, decay_rate))
    except sqlite3.OperationalError:
        # ON CONFLICT clause requires a UNIQUE index — if not present, use INSERT OR REPLACE
        conn.execute("""
            INSERT OR REPLACE INTO agent_memories
            (agent, type, name, description, content, importance, decay_rate)
            VALUES ('shared', ?, ?, ?, ?, ?, ?)
        """, (memory_type, name, description, content, importance, decay_rate))
    conn.commit()


def main():
    parser = argparse.ArgumentParser(description='Memory-based agent router and retriever')
    parser.add_argument('--prompt', type=str, default=None,
                        help='Prompt text to route or search')
    parser.add_argument('--db', type=str, default=None,
                        help='Path to cast.db')
    parser.add_argument('--min-confidence', type=float, default=0.7,
                        help='Minimum confidence threshold for route mode (default: 0.7)')
    parser.add_argument('--agent', type=str, default=None,
                        help='Agent name to retrieve memories for (retrieve mode)')
    parser.add_argument('--type', type=str, default=None,
                        help='Filter by memory type (retrieve mode)')
    parser.add_argument('--top-n', type=int, default=5,
                        help='Max memories to return in retrieve mode (default: 5)')
    parser.add_argument('--mode', type=str, default='route', choices=['route', 'retrieve'],
                        help='route: return best agent; retrieve: return ranked memory list')
    args = parser.parse_args()

    null_result = json.dumps({"agent": None, "confidence": 0.0})

    # Get prompt from arg or stdin
    prompt = args.prompt
    if prompt is None:
        if not sys.stdin.isatty():
            prompt = sys.stdin.read().strip()
        else:
            if args.mode == 'retrieve':
                print(json.dumps([]))
            else:
                print(null_result)
            return

    if not prompt:
        if args.mode == 'retrieve':
            print(json.dumps([]))
        else:
            print(null_result)
        return

    # Resolve DB path
    db_path = args.db or os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))

    if not os.path.exists(db_path):
        if args.mode == 'retrieve':
            print(json.dumps([]))
        else:
            print(null_result)
        return

    try:
        conn = sqlite3.connect(db_path)

        # Check table exists
        table_exists = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'"
        ).fetchone()

        if not table_exists:
            conn.close()
            if args.mode == 'retrieve':
                print(json.dumps([]))
            else:
                print(null_result)
            return

        # --- RETRIEVE MODE ---
        if args.mode == 'retrieve':
            agent = args.agent or 'shared'
            type_filter = args.type
            results = retrieve_memories(conn, prompt, agent, top_n=args.top_n,
                                        type_filter=type_filter)

            # Get column names for building output dicts
            cursor = conn.execute("PRAGMA table_info(agent_memories)")
            column_names = [row[1] for row in cursor.fetchall()]

            output = []
            for score, row_list in results:
                # row_list has columns + rank at end
                mem_dict = {}
                for i, col in enumerate(column_names):
                    mem_dict[col] = row_list[i] if i < len(row_list) else None
                mem_dict['score'] = round(score, 4)
                output.append(mem_dict)

            conn.close()
            print(json.dumps(output, default=str))
            return

        # --- ROUTE MODE (default, backward compatible) ---
        prompt_tokens = tokenize(prompt)
        if len(prompt_tokens) < 3:
            conn.close()
            print(null_result)
            return

        prompt_token_set = set(prompt_tokens)

        # Try FTS-based retrieval first for routing
        try:
            rows = conn.execute(
                "SELECT id, agent, content, description FROM agent_memories"
            ).fetchall()
        except sqlite3.OperationalError:
            conn.close()
            print(null_result)
            return

        best_agent = None
        best_confidence = 0.0
        best_memory_id = None
        best_reason = ""

        for mem_id, agent, content, description in rows:
            combined = ((content or '') + ' ' + (description or '')).lower()
            content_tokens = set(re.split(r'[\s\W]+', combined))
            # Count how many prompt tokens appear in memory content
            matches = prompt_token_set & content_tokens
            score = len(matches) / max(len(prompt_tokens), 1)

            if score > best_confidence or (
                score == best_confidence and mem_id > (best_memory_id or 0)
            ):
                best_confidence = score
                best_agent = agent
                best_memory_id = mem_id
                best_reason = f"Matched tokens: {', '.join(sorted(matches))}"

        conn.close()

        if best_agent and best_confidence >= args.min_confidence:
            print(json.dumps({
                "agent": best_agent,
                "confidence": round(best_confidence, 4),
                "memory_id": best_memory_id,
                "reason": best_reason,
            }))
        else:
            print(null_result)

    except Exception:
        if args.mode == 'retrieve':
            print(json.dumps([]))
        else:
            print(null_result)


if __name__ == '__main__':
    main()
