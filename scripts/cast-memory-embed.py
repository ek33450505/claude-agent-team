#!/usr/bin/env python3
"""
cast-memory-embed.py — Embedding generation and storage utility for CAST agent memories.

Uses Ollama HTTP API (nomic-embed-text model, 768 dims) to generate float32 embeddings
stored as BLOBs in agent_memories.embedding.

Usage:
  cast-memory-embed.py [--db <path>] [--backfill] [--text "<text>"]

Exit: 0 on success, 1 on DB error.
"""

import os
import sys
import json
import struct
import argparse
import sqlite3
import math

OLLAMA_EMBED_URL = 'http://localhost:11434/api/embed'
EMBED_MODEL = 'nomic-embed-text'


def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def embed_text(text, timeout=5):
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


def pack_embedding(vec):
    """Pack list[float] to bytes (float32 BLOB). 768 dims = 3072 bytes."""
    return struct.pack(f'{len(vec)}f', *vec)


def unpack_embedding(blob):
    """Unpack float32 BLOB to list[float]."""
    return list(struct.unpack(f'{len(blob)//4}f', blob))


def cosine_similarity(a, b):
    """Dot product / (norm_a * norm_b). Returns 0.0 if either norm is zero."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


def check_embedding_column(conn):
    """Return True if embedding column exists in agent_memories."""
    rows = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
    return any(row[1] == 'embedding' for row in rows)


def backfill_embeddings(conn, batch_size=50):
    """
    Select rows from agent_memories where embedding IS NULL, generate embeddings,
    store packed BLOBs. Returns (filled, skipped) counts.
    """
    if not check_embedding_column(conn):
        print("WARNING: embedding column not present in agent_memories. Run cast-memory-schema-v3.py first.",
              file=sys.stderr)
        return (0, 0)

    rows = conn.execute(
        "SELECT id, content, description FROM agent_memories WHERE embedding IS NULL LIMIT ?",
        (batch_size,)
    ).fetchall()

    filled = 0
    skipped = 0

    for row_id, content, description in rows:
        text = (content or '') + ' ' + (description or '')
        text = text.strip()
        vec = embed_text(text)
        if vec is None:
            skipped += 1
            continue
        blob = pack_embedding(vec)
        conn.execute("UPDATE agent_memories SET embedding = ? WHERE id = ?", (blob, row_id))
        filled += 1

    if filled > 0:
        conn.commit()

    return (filled, skipped)


def main():
    parser = argparse.ArgumentParser(
        description='Generate and store Ollama embeddings for CAST agent memories.'
    )
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH env var)')
    parser.add_argument('--backfill', action='store_true',
                        help='Backfill embeddings for all rows where embedding IS NULL')
    parser.add_argument('--text', metavar='TEXT',
                        help='Embed a single text string and print diagnostic output')
    args = parser.parse_args()

    if not args.backfill and not args.text:
        parser.print_help()
        sys.exit(0)

    if args.text:
        vec = embed_text(args.text)
        if vec is None:
            print("Ollama unavailable — no embedding generated.")
        else:
            blob = pack_embedding(vec)
            first3 = [round(v, 4) for v in vec[:3]]
            print(f"Embedding OK: {len(blob)} bytes, first3={first3}")
        sys.exit(0)

    if args.backfill:
        db_path = args.db if args.db else get_db_path()

        if not os.path.exists(db_path):
            print(f"ERROR: cast.db not found at {db_path}", file=sys.stderr)
            sys.exit(1)

        try:
            conn = sqlite3.connect(db_path, timeout=10)
        except sqlite3.Error as e:
            print(f"ERROR: Cannot connect to {db_path}: {e}", file=sys.stderr)
            sys.exit(1)

        try:
            filled, skipped = backfill_embeddings(conn)
            conn.close()
            print(f"Backfilled {filled} rows. Skipped {skipped} (Ollama unavailable or error).")
            sys.exit(0)
        except sqlite3.Error as e:
            print(f"ERROR: Backfill failed: {e}", file=sys.stderr)
            try:
                conn.close()
            except Exception:
                pass
            sys.exit(1)


if __name__ == '__main__':
    main()
