#!/usr/bin/env python3
"""
cast-memory-router.py — Keyword-based agent suggestion from agent_memories table.

Usage:
  cast-memory-router.py --prompt "<text>" [--db <path>] [--min-confidence 0.7]

Output (always valid JSON to stdout, always exits 0):
  {"agent": "debugger", "confidence": 0.82, "memory_id": 42, "reason": "..."}
  {"agent": null, "confidence": 0.0}
"""

import sys
import os
import json
import re
import argparse

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


def tokenize(text):
    """Split on whitespace + punctuation, lowercase, remove stop words, filter short."""
    tokens = re.split(r'[\s\W]+', text.lower())
    return [t for t in tokens if len(t) >= 3 and t not in STOP_WORDS]


def main():
    parser = argparse.ArgumentParser(description='Memory-based agent router')
    parser.add_argument('--prompt', type=str, default=None,
                        help='Prompt text to route')
    parser.add_argument('--db', type=str, default=None,
                        help='Path to cast.db')
    parser.add_argument('--min-confidence', type=float, default=0.7,
                        help='Minimum confidence threshold (default: 0.7)')
    args = parser.parse_args()

    null_result = json.dumps({"agent": None, "confidence": 0.0})

    # Get prompt from arg or stdin
    prompt = args.prompt
    if prompt is None:
        if not sys.stdin.isatty():
            prompt = sys.stdin.read().strip()
        else:
            print(null_result)
            return

    if not prompt:
        print(null_result)
        return

    # Resolve DB path
    db_path = args.db or os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))

    if not os.path.exists(db_path):
        print(null_result)
        return

    # Tokenize prompt
    prompt_tokens = tokenize(prompt)
    if len(prompt_tokens) < 3:
        print(null_result)
        return

    prompt_token_set = set(prompt_tokens)

    try:
        import sqlite3
        conn = sqlite3.connect(db_path)

        # Check table exists
        try:
            rows = conn.execute(
                "SELECT id, agent, content, description FROM agent_memories"
            ).fetchall()
        except sqlite3.OperationalError:
            # Table doesn't exist yet
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
        print(null_result)


if __name__ == '__main__':
    main()
