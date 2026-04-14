#!/usr/bin/env python3
"""
cast-session-distiller.py — Extract worth-keeping facts from a session transcript.

Reads a session transcript from stdin or --input file, applies regex/keyword
extraction rules to find feedback/project/user/reference memories, deduplicates
against existing agent_memories rows (valid_to IS NULL), and writes matches to cast.db.

Usage:
  cat transcript.txt | python3 cast-session-distiller.py [options]
  python3 cast-session-distiller.py --input transcript.txt [options]

Options:
  --input <file>          Read transcript from file instead of stdin
  --db <path>             Path to cast.db (default: ~/.claude/cast.db or $CAST_DB_PATH)
  --dry-run               Print candidates as JSON without writing to DB
  --min-importance <f>    Minimum importance threshold (default: 0.6)

Exit codes:
  0 — success (even if no candidates found)
  1 — unrecoverable error (DB connection failure on non-dry-run)
"""

import sys
import os
import re
import json
import argparse
import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cast_db import db_query, db_execute


# ---------------------------------------------------------------------------
# Extraction patterns — (compiled_regex, memory_type, importance)
# Patterns are evaluated in order; first match per sentence wins.
# ---------------------------------------------------------------------------
EXTRACTION_PATTERNS = [
    (re.compile(
        r"(?:don't|dont|do not|stop doing|never)\s+.{5,}",
        re.IGNORECASE
    ), 'feedback', 0.85),

    (re.compile(
        r"(?:always|make sure|remember that|remember to)\s+.{5,}",
        re.IGNORECASE
    ), 'feedback', 0.75),

    (re.compile(
        r"(?:the reason (?:we|we're|we are)|because of|driven by)\s+.{5,}",
        re.IGNORECASE
    ), 'project', 0.70),

    (re.compile(
        r"(?:we decided|decision:)\s+.{3,}",
        re.IGNORECASE
    ), 'project', 0.70),

    (re.compile(
        r".+(?:\bis at path\b|\blives in\b|\blocated at\b)\s+.{3,}",
        re.IGNORECASE
    ), 'reference', 0.65),

    (re.compile(
        r"(?:I prefer|I like)\s+.{5,}",
        re.IGNORECASE
    ), 'user', 0.60),
]


def slugify(text, max_words=8):
    """Convert text to a slug: first N words, lowercased, joined by hyphens."""
    words = re.split(r'\W+', text.lower())
    words = [w for w in words if w][:max_words]
    return '-'.join(words) if words else 'memory'


def split_sentences(text):
    """Split text into (sentence, surrounding_context) tuples."""
    sentence_pattern = re.compile(r'(?<=[.!?])\s+')
    sentences = sentence_pattern.split(text.strip())
    result = []
    for i, sentence in enumerate(sentences):
        sentence = sentence.strip()
        if not sentence:
            continue
        # Gather up to 1 sentence before and 1 after for context
        parts = [sentence]
        if i > 0:
            parts = [sentences[i - 1].strip()] + parts
        if i < len(sentences) - 1:
            parts = parts + [sentences[i + 1].strip()]
        context = ' '.join(p for p in parts if p)
        result.append((sentence, context))
    return result


def extract_candidates(text, min_importance=0.6):
    """
    Extract memory candidates from transcript text.

    Returns list of dicts: {name, description, content, type, importance}
    """
    candidates = []
    seen_names = set()

    sentence_tuples = split_sentences(text)

    for sentence, context in sentence_tuples:
        for pattern, mem_type, importance in EXTRACTION_PATTERNS:
            if importance < min_importance:
                continue
            match = pattern.search(sentence)
            if match:
                # Use the full sentence as description (truncated to 200 chars)
                description = sentence[:200]

                # Generate slug name from matched sentence
                name = slugify(sentence, max_words=8)

                # Avoid duplicate names within this run
                if name in seen_names:
                    continue
                seen_names.add(name)

                candidates.append({
                    'name': name,
                    'description': description,
                    'content': context[:500],  # up to 2 surrounding sentences for context
                    'type': mem_type,
                    'importance': importance,
                })
                break  # first pattern match wins per sentence

    return candidates


def check_duplicate(name):
    """Return True if a non-superseded shared memory with this name exists."""
    try:
        # Check if valid_to column exists
        col_rows = db_query("PRAGMA table_info(agent_memories)")
        col_names = {row[1] for row in col_rows}

        if 'valid_to' in col_names:
            rows = db_query(
                "SELECT id FROM agent_memories WHERE agent = 'shared' AND name = ? "
                "AND valid_to IS NULL LIMIT 1",
                (name,)
            )
        else:
            # Migration not yet run — check without temporal filter
            rows = db_query(
                "SELECT id FROM agent_memories WHERE agent = 'shared' AND name = ? LIMIT 1",
                (name,)
            )
        return len(rows) > 0
    except Exception:
        return False


def insert_memory(candidate):
    """Insert a candidate memory into agent_memories as agent='shared'."""
    now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    # Check if valid_from column exists
    col_rows = db_query("PRAGMA table_info(agent_memories)")
    col_names = {row[1] for row in col_rows}

    if 'valid_from' in col_names:
        db_execute("""
            INSERT INTO agent_memories
            (agent, type, name, description, content, importance, valid_from, created_at, updated_at)
            VALUES ('shared', ?, ?, ?, ?, ?, datetime('now'), ?, ?)
        """, (
            candidate['type'],
            candidate['name'],
            candidate['description'],
            candidate['content'],
            candidate['importance'],
            now,
            now,
        ))
    else:
        # valid_from column may not exist yet (migration not run) — insert without it
        db_execute("""
            INSERT INTO agent_memories
            (agent, type, name, description, content, importance, created_at, updated_at)
            VALUES ('shared', ?, ?, ?, ?, ?, ?, ?)
        """, (
            candidate['type'],
            candidate['name'],
            candidate['description'],
            candidate['content'],
            candidate['importance'],
            now,
            now,
        ))


def main():
    parser = argparse.ArgumentParser(
        description='Extract worth-keeping facts from a session transcript'
    )
    parser.add_argument('--input', type=str, default=None,
                        help='Read transcript from file instead of stdin')
    parser.add_argument('--db', type=str, default=None,
                        help='Path to cast.db (default: ~/.claude/cast.db or $CAST_DB_PATH)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print candidates as JSON without writing to DB')
    parser.add_argument('--min-importance', type=float, default=0.6,
                        help='Minimum importance threshold (default: 0.6)')
    args = parser.parse_args()

    # Read transcript
    if args.input:
        try:
            with open(args.input, 'r', encoding='utf-8') as f:
                text = f.read()
        except Exception as e:
            print(f"ERROR: Cannot read input file {args.input}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        try:
            text = sys.stdin.read()
        except Exception:
            text = ''

    if not text or not text.strip():
        # Empty input — exit cleanly
        if args.dry_run:
            print(json.dumps([]))
        sys.exit(0)

    candidates = extract_candidates(text, min_importance=args.min_importance)

    if args.dry_run:
        print(json.dumps(candidates, indent=2))
        sys.exit(0)

    if not candidates:
        sys.exit(0)

    # Resolve DB path — set env var so cast_db._get_db_path() picks it up
    db_path = args.db or os.environ.get('CAST_DB_PATH',
                                         os.path.expanduser('~/.claude/cast.db'))

    if not os.path.exists(db_path):
        print(f"[distiller] DB not found at {db_path} — skipping write", file=sys.stderr)
        sys.exit(0)

    # Override CAST_DB_PATH so cast_db functions use the resolved path
    os.environ['CAST_DB_PATH'] = db_path

    inserted = 0
    skipped = 0
    for candidate in candidates:
        if check_duplicate(candidate['name']):
            skipped += 1
            continue
        try:
            insert_memory(candidate)
            inserted += 1
        except Exception as e:
            print(f"[distiller] WARN: failed to insert '{candidate['name']}': {e}",
                  file=sys.stderr)

    print(f"[distiller] {inserted} inserted, {skipped} skipped (duplicates)",
          file=sys.stderr)
    sys.exit(0)


if __name__ == '__main__':
    main()
