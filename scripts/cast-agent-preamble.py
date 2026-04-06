#!/usr/bin/env python3
"""
cast-agent-preamble.py — Procedural memory preamble generator for CAST agents.

A fast CLI tool that queries agent_memories and outputs a formatted markdown block
suitable for prepending to an agent's prompt. No embeddings or Ollama calls.

Usage:
  cast-agent-preamble.py --agent <name> [--types procedural,feedback] [--top-n 5] [--db PATH]

Output: markdown block to stdout. Empty string if no memories. Exit 0 always.
"""

import os
import sys
import argparse
import sqlite3


def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def main():
    parser = argparse.ArgumentParser(
        description='Generate procedural memory preamble for a CAST agent.'
    )
    parser.add_argument('--agent', required=True, help='Agent name')
    parser.add_argument('--types', default='procedural,feedback',
                        help='Comma-separated memory types (default: procedural,feedback)')
    parser.add_argument('--top-n', type=int, default=5,
                        help='Max memories to include (default: 5)')
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH)')
    args = parser.parse_args()

    db_path = args.db if args.db else get_db_path()

    # Graceful degradation: if DB missing, output empty string
    if not os.path.exists(db_path):
        sys.exit(0)

    try:
        conn = sqlite3.connect(db_path, timeout=5)
    except sqlite3.Error:
        sys.exit(0)

    try:
        # Check if agent_memories table exists
        table_check = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'"
        ).fetchone()
        if not table_check:
            conn.close()
            sys.exit(0)

        # Parse types
        types = [t.strip() for t in args.types.split(',') if t.strip()]
        if not types:
            conn.close()
            sys.exit(0)

        # Build parameterized query
        placeholders = ','.join('?' for _ in types)
        sql = f"""
            SELECT name, description, content, importance
            FROM agent_memories
            WHERE (agent = ? OR agent = 'shared')
              AND type IN ({placeholders})
            ORDER BY importance DESC
            LIMIT ?
        """
        params = [args.agent] + types + [args.top_n]
        rows = conn.execute(sql, params).fetchall()
        conn.close()

        if not rows:
            sys.exit(0)

        # Format output
        lines = ["## Procedural Memory (auto-loaded)", ""]
        for name, description, content, importance in rows:
            name = name or ''
            description = description or ''
            content = content or ''
            # Truncate content to first 150 chars
            content_preview = content[:150]
            if len(content) > 150:
                content_preview += '...'
            lines.append(f"**{name}:** {description} — {content_preview}")
            lines.append("")

        print('\n'.join(lines))
        sys.exit(0)

    except Exception:
        # Never crash — graceful degradation
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(0)


if __name__ == '__main__':
    main()
