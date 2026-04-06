#!/usr/bin/env python3
"""
cast-session-distiller.py — End-of-session heuristic memory extraction for CAST.

Reads agent_runs from cast.db and writes pattern-matched memories to agent_memories.
No LLM calls — pure sqlite3 queries and regex pattern matching.

Usage:
  cast-session-distiller.py [--db <path>] [--session-id <id>] [--dry-run]

Output: JSON object with distilled memories and skipped count.
Exit: 0 always (exit 1 only on DB connection failure).
"""

import os
import sys
import json
import re
import argparse
import sqlite3
from datetime import datetime, timezone

PATH_REGEX = re.compile(r'/[^\s\'")\]]{5,}')
DATE_SUFFIX = datetime.now().strftime('%Y%m%d')
REPO_DIR = os.path.expanduser('~/Projects/personal/claude-agent-team')


def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def get_agent_runs_columns(conn):
    """Discover agent_runs columns via PRAGMA."""
    rows = conn.execute("PRAGMA table_info(agent_runs)").fetchall()
    return {row[1] for row in rows}


def check_table_exists(conn, table_name):
    """Return True if table exists."""
    result = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        (table_name,)
    ).fetchone()
    return result is not None


def memory_exists(conn, name):
    """Return True if a memory with this name already exists for agent='shared'."""
    row = conn.execute(
        "SELECT id FROM agent_memories WHERE agent='shared' AND name=?",
        (name,)
    ).fetchone()
    return row is not None


def count_blocked_memories(conn, agent):
    """Count existing BLOCKED memories for this agent."""
    row = conn.execute(
        "SELECT COUNT(*) FROM agent_memories WHERE content LIKE '%BLOCKED%' AND content LIKE ?",
        (f'%{agent}%',)
    ).fetchone()
    return row[0] if row else 0


def write_memory(conn, name, mem_type, description, content, importance, decay_rate=0.995):
    """Write a memory via direct sqlite3 INSERT."""
    conn.execute(
        """INSERT INTO agent_memories
           (agent, project, type, name, description, content, importance, decay_rate)
           VALUES ('shared', 'cast', ?, ?, ?, ?, ?, ?)""",
        (mem_type, name, description, content, importance, decay_rate)
    )
    conn.commit()


def extract_memories(conn, run_row, col_names, dry_run=False):
    """
    Extract heuristic memories from a single agent_runs row.
    Returns list of memory dicts (written or would-be-written) and skipped count.
    """
    def safe_get(field, default=''):
        return run_row[col_names.index(field)] if field in col_names else default

    run_id = safe_get('id', None)
    session_id = safe_get('session_id', None)
    agent = safe_get('agent', 'unknown')
    status = safe_get('status', '')
    task_summary = safe_get('task_summary', '') or ''

    distilled = []
    skipped = 0

    # --- Rule a: BLOCKED pattern ---
    if status == 'BLOCKED':
        excerpt = task_summary[:200].strip()
        name = f'blocked-{agent}-{DATE_SUFFIX}'
        content = f'Agent {agent} was BLOCKED on task: {excerpt}'

        # Rule d: Repeated failure detection
        blocked_count = count_blocked_memories(conn, agent)
        importance = 0.85 if blocked_count >= 2 else 0.7

        if memory_exists(conn, name):
            skipped += 1
        else:
            mem = {
                'name': name,
                'type': 'procedural',
                'description': f'BLOCKED status from {agent} on {DATE_SUFFIX}',
                'content': content,
                'importance': importance,
                'decay_rate': 0.990
            }
            if not dry_run:
                write_memory(conn, name, 'procedural',
                             mem['description'], content, importance, 0.990)
            distilled.append({k: v for k, v in mem.items()})

    # --- Rule b: DONE_WITH_CONCERNS pattern ---
    elif status == 'DONE_WITH_CONCERNS':
        excerpt = task_summary[:200].strip()
        name = f'concern-{agent}-{DATE_SUFFIX}'
        content = f'Agent {agent} completed with concerns: {excerpt}'
        importance = 0.65

        if memory_exists(conn, name):
            skipped += 1
        else:
            mem = {
                'name': name,
                'type': 'feedback',
                'description': f'DONE_WITH_CONCERNS from {agent} on {DATE_SUFFIX}',
                'content': content,
                'importance': importance,
                'decay_rate': 0.995
            }
            if not dry_run:
                write_memory(conn, name, 'feedback',
                             mem['description'], content, importance)
            distilled.append({k: v for k, v in mem.items()})

    # --- Rule c: File path references ---
    if task_summary:
        paths = list(dict.fromkeys(PATH_REGEX.findall(task_summary)))[:5]
        for path in paths:
            if not os.path.exists(path):
                basename = os.path.basename(path)
                name = f'stale-path-{basename}'
                content = f'Path referenced in session no longer exists: {path}'
                importance = 0.5

                if memory_exists(conn, name):
                    skipped += 1
                else:
                    mem = {
                        'name': name,
                        'type': 'reference',
                        'description': f'Stale path reference: {path}',
                        'content': content,
                        'importance': importance,
                        'decay_rate': 0.995
                    }
                    if not dry_run:
                        write_memory(conn, name, 'reference',
                                     mem['description'], content, importance)
                    distilled.append({k: v for k, v in mem.items()})

    return distilled, skipped


def main():
    parser = argparse.ArgumentParser(
        description='End-of-session heuristic memory extraction for CAST.'
    )
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH)')
    parser.add_argument('--session-id', help='Session ID to process (default: most recent run)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print what would be written without writing to DB')
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
        # Check tables exist
        if not check_table_exists(conn, 'agent_runs'):
            output = {
                'session_id': args.session_id,
                'agent_run_id': None,
                'distilled': [],
                'skipped': 0,
                'note': 'agent_runs table not found'
            }
            print(json.dumps(output, indent=2))
            conn.close()
            sys.exit(0)

        if not check_table_exists(conn, 'agent_memories'):
            output = {
                'session_id': args.session_id,
                'agent_run_id': None,
                'distilled': [],
                'skipped': 0,
                'note': 'agent_memories table not found'
            }
            print(json.dumps(output, indent=2))
            conn.close()
            sys.exit(0)

        # Discover columns
        col_names_set = get_agent_runs_columns(conn)
        col_names = [r[1] for r in conn.execute("PRAGMA table_info(agent_runs)").fetchall()]

        # Fetch run(s) to process
        if args.session_id:
            if 'session_id' in col_names_set:
                rows = conn.execute(
                    "SELECT * FROM agent_runs WHERE session_id=? ORDER BY id DESC",
                    (args.session_id,)
                ).fetchall()
            else:
                rows = []
        else:
            # Most recent single row
            row = conn.execute(
                "SELECT * FROM agent_runs ORDER BY id DESC LIMIT 1"
            ).fetchone()
            rows = [row] if row else []

        if not rows:
            output = {
                'session_id': args.session_id,
                'agent_run_id': None,
                'distilled': [],
                'skipped': 0,
                'note': 'No agent_runs rows found'
            }
            print(json.dumps(output, indent=2))
            conn.close()
            sys.exit(0)

        all_distilled = []
        total_skipped = 0
        first_run_id = rows[0][col_names.index('id')] if 'id' in col_names_set else None
        first_session_id = rows[0][col_names.index('session_id')] if 'session_id' in col_names_set else args.session_id

        for run_row in rows:
            d, s = extract_memories(conn, run_row, col_names, dry_run=args.dry_run)
            all_distilled.extend(d)
            total_skipped += s

        output = {
            'session_id': first_session_id,
            'agent_run_id': first_run_id,
            'distilled': all_distilled,
            'skipped': total_skipped
        }

        print(json.dumps(output, indent=2))
        conn.close()
        sys.exit(0)

    except sqlite3.Error as e:
        print(f"ERROR: Distillation failed: {e}", file=sys.stderr)
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
