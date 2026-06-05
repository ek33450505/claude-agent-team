#!/usr/bin/env python3
"""
cast-memory-router.py — FTS5-indexed, relevance-scored memory router for CAST agents.

Usage (route mode — default, backward compatible):
  cast-memory-router.py --prompt "<text>" [--db <path>] [--min-confidence 0.7]
  echo "text" | cast-memory-router.py

Usage (retrieve mode):
  cast-memory-router.py --mode retrieve --agent <name> --prompt "<text>" [--top-n 5] [--type <type>]
  cast-memory-router.py --mode retrieve --agent <name> --prompt "<text>" --fts-only [--top-n 5]

Flags:
  --fts-only    Skip Ollama embed call entirely; use cosine_sim=0.0. Reduces latency from ~3s to ~10-30ms.

Output (route mode):
  {"agent": "debugger", "confidence": 0.82, "memory_id": 42, "reason": "..."}
  {"agent": null, "confidence": 0.0}

Output (retrieve mode):
  [{"score": 0.91, "agent": "shared", "type": "procedural", "name": "...", ...}, ...]
"""

# ─── PHASE 15 CONVERGENCE MARKER ─────────────────────────────────────────────
# Convergence target: native Claude Code auto-memory (MEMORY.md auto-load).
# STATUS: BLOCKED — do NOT unwire this router from the UserPromptSubmit hook chain.
# Native auto-memory is STATIC (session-start MEMORY.md load only); it cannot
# replicate this router's DYNAMIC per-prompt FTS retrieval + relevance scoring.
# Two-tier memory model:
#   Tier 1 (native): MEMORY.md auto-load — static, session-start (project +
#                    agent-memory-local/<agent>/MEMORY.md). First ~200 lines loaded.
#   Tier 2 (this router): dynamic per-prompt FTS retrieval, scored, DB-backed.
# Preferred WRITE path for new agent memories: agent-memory-local/<agent>/MEMORY.md.
# Retire this router ONLY when Claude Code exposes a native per-prompt dynamic
# context-injection API. See ~/.claude/research/2026-06-03-anthropic-devs-claude-code-convergence.md (Phase 15).
# ─────────────────────────────────────────────────────────────────────────────

import sys
import os
import json
import re
import math
import argparse
import sqlite3
import struct
import urllib.parse
import hashlib
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cast_db import db_query, db_execute, db_write, _connect

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

VALID_TYPES = {'user', 'feedback', 'project', 'reference', 'procedural', 'user_profile'}

OLLAMA_EMBED_URL = 'http://localhost:11434/api/embed'
EMBED_MODEL = 'nomic-embed-text'

_ALLOWED_EMBED_HOSTS = {'localhost', '127.0.0.1', '::1'}


def _is_safe_url(url: str) -> bool:
    """Return True only if url has an allowed scheme and a local hostname."""
    try:
        parsed = urllib.parse.urlparse(url)
    except Exception:
        return False
    if parsed.scheme not in ('http', 'https'):
        return False
    hostname = parsed.hostname or ''
    return hostname in _ALLOWED_EMBED_HOSTS


def embed_text(text, timeout=3):
    """Call Ollama embed API. Returns list[float] or None on any error."""
    try:
        if not _is_safe_url(OLLAMA_EMBED_URL):
            raise ValueError(f"Unsafe Ollama embed URL: {OLLAMA_EMBED_URL!r}")
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


def invalidate_memory(memory_id):
    """Mark a memory as superseded by setting valid_to = now."""
    db_execute(
        "UPDATE agent_memories SET valid_to = datetime('now') WHERE id = ?",
        (memory_id,)
    )


def _log_injection(session_id: str, prompt: str, fact_id: int, score: float,
                   score_breakdown_dict: dict) -> None:
    """Write one row to injection_log for each fact that survives the score threshold.

    injection_log.id is an INTEGER primary key (autoincrement) — omit it so SQLite
    assigns it automatically. fact_id is INTEGER NOT NULL so we skip logging if it is
    None (e.g. a memory row with no integer id).
    """
    try:
        if fact_id is None:
            return  # fact_id NOT NULL — skip rows without a numeric id
        prompt_hash = hashlib.md5((prompt or '').encode('utf-8')).hexdigest()
        db_write('injection_log', {
            'session_id': session_id,
            'prompt_hash': prompt_hash,
            'fact_id': int(fact_id),
            'score': float(score),
            'score_breakdown': json.dumps(score_breakdown_dict),
            'injected_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        })
    except Exception as e:
        try:
            from cast_db import log_hook_failure
            log_hook_failure('cast-memory-router:injection_log', -1, str(e), session_id)
        except Exception:
            pass


def retrieve_memories(prompt, agent, top_n=5, type_filter=None, include_history=False, fts_only=False, agent_type=None):
    """Return top-N memories for agent, ranked by relevance. Includes shared pool and user_profile (global) facts.

    If agent_type is one of (commit, push, merge, code-reviewer), exclude type IN ('project', 'reference').
    For other agent types, no filtering is applied.
    """
    conn = _connect()

    # Determine if we should filter out project/reference for lightweight agents
    lightweight_agents = {'commit', 'push', 'merge', 'code-reviewer'}
    should_filter = agent_type in lightweight_agents if agent_type else False

    # Check FTS availability
    has_fts = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'"
    ).fetchone() is not None

    # Get column names for flexible field access
    cursor = conn.execute("PRAGMA table_info(agent_memories)")
    column_names = [row[1] for row in cursor.fetchall()]

    # Temporal filter: hide superseded memories unless --history requested
    # Gate on column existence so function degrades gracefully before migration runs
    has_valid_to = 'valid_to' in column_names
    if has_valid_to and not include_history:
        temporal_clause = "AND am.valid_to IS NULL"
    else:
        temporal_clause = ""

    # Type filter: either explicit --type filter OR implicit lightweight-agent filter
    type_params = ()
    if type_filter:
        type_clause = "AND am.type = ?"
        type_params = (type_filter,)
    elif should_filter:
        type_clause = "AND am.type NOT IN ('project', 'reference')"
    else:
        type_clause = ""

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
                    AND (am.agent = ? OR am.agent = 'shared' OR (am.agent = 'global' AND am.type = 'user_profile'))
                    {temporal_clause}
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
            WHERE (am.agent = ? OR am.agent = 'shared' OR (am.agent = 'global' AND am.type = 'user_profile'))
            {temporal_clause}
            {type_clause}
        """
        params = (agent,) + type_params
        rows = conn.execute(sql, params).fetchall()

    # Build column_names + 'rank' for scoring
    col_names_with_rank = column_names + ['rank']

    # Attempt cosine re-rank (skipped when --fts-only; cosine term contributes 0.0)
    query_embedding = None if fts_only else embed_text(prompt)

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
    conn.close()
    return [(s, r) for s, r in scored[:top_n]]


def write_shared_memory(name, description, content, memory_type='project',
                        importance=0.5, decay_rate=0.993):
    """Write a memory to the shared pool (agent='shared')."""
    if memory_type not in VALID_TYPES:
        raise ValueError(f"Invalid memory type: {memory_type}. Must be one of {VALID_TYPES}")

    # Check if UNIQUE constraint on (agent, name) exists by trying ON CONFLICT
    # If the constraint doesn't exist, this will fall back to a plain insert
    try:
        db_execute("""
            INSERT INTO agent_memories (agent, type, name, description, content, importance, decay_rate)
            VALUES ('shared', ?, ?, ?, ?, ?, ?)
            ON CONFLICT(agent, name) DO UPDATE SET
                content=excluded.content,
                description=excluded.description,
                importance=excluded.importance,
                updated_at=CURRENT_TIMESTAMP,
                valid_from=datetime('now'),
                valid_to=NULL
        """, (memory_type, name, description, content, importance, decay_rate))
    except sqlite3.OperationalError:
        # ON CONFLICT clause requires a UNIQUE index — if not present, use INSERT OR REPLACE
        db_execute("""
            INSERT OR REPLACE INTO agent_memories
            (agent, type, name, description, content, importance, decay_rate)
            VALUES ('shared', ?, ?, ?, ?, ?, ?)
        """, (memory_type, name, description, content, importance, decay_rate))


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
    parser.add_argument('--history', action='store_true',
                        help='Include superseded (valid_to IS NOT NULL) memories in retrieve mode')
    parser.add_argument('--fts-only', action='store_true', default=False,
                        help='Skip Ollama embed call; use cosine_sim=0.0 (faster, ~10-30ms)')
    parser.add_argument('--agent-type', type=str, default=None,
                        help='Agent type for filtering (commit|push|merge|code-reviewer excludes project/reference types)')
    parser.add_argument('--invalidate', type=int, default=None, metavar='ID',
                        help='Mark memory with given ID as superseded (sets valid_to=now) and exit')
    parser.add_argument('--session-id', type=str, default=None,
                        help='Session ID for injection_log telemetry (retrieve mode)')
    args = parser.parse_args()

    null_result = json.dumps({"agent": None, "confidence": 0.0})

    # Resolve DB path — set env var so cast_db._get_db_path() picks it up
    db_path = args.db or os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
    os.environ['CAST_DB_PATH'] = db_path

    # --- INVALIDATE MODE (early exit, no prompt required) ---
    if args.invalidate is not None:
        if not os.path.exists(db_path):
            print(f"ERROR: Database not found at {db_path}", file=sys.stderr)
            sys.exit(1)
        try:
            invalidate_memory(args.invalidate)
            print(json.dumps({"invalidated": args.invalidate}))
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        return

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

    if not os.path.exists(db_path):
        if args.mode == 'retrieve':
            print(json.dumps([]))
        else:
            print(null_result)
        return

    try:
        # Check table exists
        table_rows = db_query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'"
        )

        if not table_rows:
            if args.mode == 'retrieve':
                print(json.dumps([]))
            else:
                print(null_result)
            return

        # --- RETRIEVE MODE ---
        if args.mode == 'retrieve':
            agent = args.agent or 'shared'
            type_filter = args.type
            session_id = args.session_id or os.environ.get('CAST_SESSION_ID', '')
            results = retrieve_memories(prompt, agent, top_n=args.top_n,
                                        type_filter=type_filter,
                                        include_history=args.history,
                                        fts_only=args.fts_only,
                                        agent_type=args.agent_type)

            # Get column names for building output dicts
            col_rows = db_query("PRAGMA table_info(agent_memories)")
            column_names = [row[1] for row in col_rows]

            output = []
            for score, row_list in results:
                # row_list has columns + rank at end
                mem_dict = {}
                for i, col in enumerate(column_names):
                    mem_dict[col] = row_list[i] if i < len(row_list) else None
                mem_dict['score'] = round(score, 4)
                output.append(mem_dict)
                # Log each injected fact to injection_log for observability
                _log_injection(
                    session_id=session_id,
                    prompt=prompt,
                    fact_id=mem_dict.get('id'),
                    score=score,
                    score_breakdown_dict={
                        'fts_rank': row_list[-1] if row_list else 0.0,
                        'cosine_sim': mem_dict.get('score', 0.0),
                        'agent': agent,
                    },
                )

            print(json.dumps(output, default=str))
            return

        # --- ROUTE MODE (default, backward compatible) ---
        prompt_tokens = tokenize(prompt)
        if len(prompt_tokens) < 3:
            print(null_result)
            return

        prompt_token_set = set(prompt_tokens)

        # Try FTS-based retrieval first for routing
        try:
            rows = db_query(
                "SELECT id, agent, content, description FROM agent_memories"
            )
        except sqlite3.OperationalError:
            print(null_result)
            return

        best_agent = None
        best_confidence = 0.0
        best_memory_id = None
        best_reason = ""

        for row in rows:
            mem_id, agent, content, description = row[0], row[1], row[2], row[3]
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
