#!/usr/bin/env python3
"""
cast-memory-consolidate.py — Weekly memory consolidation for CAST agent memories.

Performs four sequential operations:
  1. Decay importance scores (exponential decay)
  2. Deduplicate by cosine similarity (>0.95 within same agent+type)
  3. Archive low-value memories (importance < 0.1) to archived_memories
  4. Promote frequently retrieved memories (retrieval_count >= 5)

Output: JSON summary to stdout.

Cron entry (weekly Sunday 3am):
  0 3 * * 0 python3 /Users/edkubiak/Projects/personal/claude-agent-team/scripts/cast-memory-consolidate.py >> ~/.claude/logs/memory-consolidate.log 2>&1

Usage:
  cast-memory-consolidate.py [--db PATH] [--dry-run]
"""

import os
import sys
import json
import math
import struct
import argparse
import sqlite3
from datetime import datetime, timezone


# --- Copied from cast-memory-router.py / cast-memory-embed.py (no cross-script imports) ---

def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def unpack_embedding(blob):
    """Unpack float32 BLOB to list of floats."""
    return list(struct.unpack(f'{len(blob)//4}f', blob))


def pack_embedding(vec):
    """Pack list[float] to bytes (float32 BLOB). 768 dims = 3072 bytes."""
    return struct.pack(f'{len(vec)}f', *vec)


def cosine_similarity(a, b):
    """Dot product / (norm_a * norm_b). Returns 0.0 if either norm is zero."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


# --- End copied functions ---


def table_exists(conn, table_name):
    """Return True if the table exists."""
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        (table_name,)
    ).fetchone()
    return row is not None


def column_exists(conn, table_name, column_name):
    """Return True if the column exists in the table."""
    rows = conn.execute(f"PRAGMA table_info({table_name})").fetchall()
    return any(row[1] == column_name for row in rows)


def op_decay(conn, dry_run=False):
    """Operation 1: Apply exponential decay to importance scores."""
    now = datetime.now(timezone.utc)
    rows = conn.execute(
        "SELECT id, importance, decay_rate, updated_at FROM agent_memories"
    ).fetchall()

    count = 0
    for row_id, importance, decay_rate, updated_at_str in rows:
        if importance is None:
            importance = 0.5
        if decay_rate is None:
            decay_rate = 0.995

        # Parse updated_at
        try:
            updated_at = datetime.fromisoformat(updated_at_str.replace('Z', '+00:00'))
            if updated_at.tzinfo is None:
                updated_at = updated_at.replace(tzinfo=timezone.utc)
        except Exception:
            continue

        hours_since = (now - updated_at).total_seconds() / 3600
        new_importance = importance * math.exp(-decay_rate * hours_since / 8760)
        new_importance = round(new_importance, 6)

        if new_importance != importance:
            if not dry_run:
                conn.execute(
                    "UPDATE agent_memories SET importance = ? WHERE id = ?",
                    (new_importance, row_id)
                )
            count += 1

    if not dry_run:
        conn.commit()
    return count


def op_deduplicate(conn, dry_run=False):
    """Operation 2: Remove duplicates with cosine similarity > 0.95 within same agent+type."""
    # Skip if embedding column doesn't exist
    if not column_exists(conn, 'agent_memories', 'embedding'):
        return 0

    # Get distinct (agent, type) pairs
    pairs = conn.execute(
        "SELECT DISTINCT agent, type FROM agent_memories WHERE embedding IS NOT NULL"
    ).fetchall()

    merged = 0
    for agent, mem_type in pairs:
        rows = conn.execute(
            "SELECT id, importance, embedding FROM agent_memories "
            "WHERE agent = ? AND type = ? AND embedding IS NOT NULL "
            "ORDER BY importance DESC, id ASC",
            (agent, mem_type)
        ).fetchall()

        # Track IDs to delete
        to_delete = set()
        embeddings = []
        for row_id, importance, blob in rows:
            try:
                vec = unpack_embedding(blob)
                embeddings.append((row_id, importance, vec))
            except Exception:
                continue

        # O(n^2) comparison within group
        for i in range(len(embeddings)):
            if embeddings[i][0] in to_delete:
                continue
            for j in range(i + 1, len(embeddings)):
                if embeddings[j][0] in to_delete:
                    continue
                sim = cosine_similarity(embeddings[i][2], embeddings[j][2])
                if sim > 0.95:
                    # Delete the one with lower importance (j comes after i in importance-desc order)
                    to_delete.add(embeddings[j][0])

        for row_id in to_delete:
            if not dry_run:
                conn.execute("DELETE FROM agent_memories WHERE id = ?", (row_id,))
            merged += 1

    if not dry_run:
        conn.commit()
    return merged


def op_archive(conn, dry_run=False):
    """Operation 3: Move low-importance memories to archived_memories."""
    if not table_exists(conn, 'archived_memories'):
        print("WARNING: archived_memories table not found. Skipping archive step.", file=sys.stderr)
        return 0

    # Count rows to archive
    rows = conn.execute(
        "SELECT COUNT(*) FROM agent_memories WHERE importance < 0.1"
    ).fetchone()
    count = rows[0] if rows else 0

    if count > 0 and not dry_run:
        # Get column names for agent_memories
        col_info = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
        am_cols = [r[1] for r in col_info]

        # Get column names for archived_memories (minus archived_at which gets DEFAULT)
        arch_col_info = conn.execute("PRAGMA table_info(archived_memories)").fetchall()
        arch_cols = [r[1] for r in arch_col_info]

        # Find common columns (excluding archived_at which auto-fills)
        common_cols = [c for c in am_cols if c in arch_cols and c != 'archived_at']
        col_list = ', '.join(common_cols)

        conn.execute(f"""
            INSERT INTO archived_memories ({col_list}, archived_at)
            SELECT {col_list}, CURRENT_TIMESTAMP FROM agent_memories WHERE importance < 0.1
        """)
        conn.execute("DELETE FROM agent_memories WHERE importance < 0.1")
        conn.commit()

    return count


def op_promote(conn, dry_run=False):
    """Operation 4: Bump importance for frequently retrieved memories."""
    if not column_exists(conn, 'agent_memories', 'retrieval_count'):
        return 0

    rows = conn.execute(
        "SELECT id, importance FROM agent_memories WHERE retrieval_count >= 5"
    ).fetchall()

    count = 0
    for row_id, importance in rows:
        if importance is None:
            importance = 0.5
        new_importance = min(1.0, importance + 0.1)
        if not dry_run:
            conn.execute(
                "UPDATE agent_memories SET importance = ?, retrieval_count = 0 WHERE id = ?",
                (new_importance, row_id)
            )
        count += 1

    if not dry_run:
        conn.commit()
    return count


def main():
    parser = argparse.ArgumentParser(
        description='Weekly memory consolidation for CAST agent memories.'
    )
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print what would happen without writing')
    args = parser.parse_args()

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
        # Check agent_memories table exists
        if not table_exists(conn, 'agent_memories'):
            print(f"ERROR: agent_memories table not found in {db_path}", file=sys.stderr)
            conn.close()
            sys.exit(1)

        decayed = op_decay(conn, dry_run=args.dry_run)
        merged = op_deduplicate(conn, dry_run=args.dry_run)
        archived = op_archive(conn, dry_run=args.dry_run)
        promoted = op_promote(conn, dry_run=args.dry_run)

        conn.close()

        result = {
            "decayed": decayed,
            "merged": merged,
            "archived": archived,
            "promoted": promoted,
            "timestamp": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        }
        print(json.dumps(result))
        sys.exit(0)

    except sqlite3.Error as e:
        print(f"ERROR: Consolidation failed: {e}", file=sys.stderr)
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: Unexpected error: {e}", file=sys.stderr)
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(1)


if __name__ == '__main__':
    main()
