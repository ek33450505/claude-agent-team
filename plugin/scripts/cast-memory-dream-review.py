#!/usr/bin/env python3
"""
cast-memory-dream-review.py — List pending (unpromoted) dream output dirs.

Reads memory_consolidation_runs where status='completed', checks that:
  - output_path still exists on disk
  - output_path does NOT contain a .promoted sentinel file

Prints a table: run_id | project_id | output_path | completed_at | files_changed_count

Usage:
  cast-memory-dream-review.py [--project-id <id>] [--db <path>] [--json]
"""

import os
import sys
import json
import argparse
import sqlite3

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from cast_db import db_query
    _CAST_DB_AVAILABLE = True
except Exception:
    _CAST_DB_AVAILABLE = False


def get_db_path():
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def fetch_completed_runs(db_path, project_id=None):
    """Return completed runs from memory_consolidation_runs."""
    if _CAST_DB_AVAILABLE:
        # cast_db.db_query(sql, params) — uses env-var DB path internally
        if project_id:
            rows = db_query(
                "SELECT run_id, project_id, output_path, completed_at, candidates_written "
                "FROM memory_consolidation_runs WHERE status='completed' AND project_id=? "
                "ORDER BY completed_at DESC",
                (project_id,)
            )
        else:
            rows = db_query(
                "SELECT run_id, project_id, output_path, completed_at, candidates_written "
                "FROM memory_consolidation_runs WHERE status='completed' "
                "ORDER BY completed_at DESC"
            )
        # Rows are sqlite3.Row objects; convert to dicts
        return [dict(r) for r in rows] if rows else []
    else:
        # Fallback: direct sqlite3 (cast_db not available)
        try:
            conn = sqlite3.connect(db_path, timeout=10)
            conn.row_factory = sqlite3.Row
            if project_id:
                cur = conn.execute(
                    "SELECT run_id, project_id, output_path, completed_at, candidates_written "
                    "FROM memory_consolidation_runs WHERE status='completed' AND project_id=? "
                    "ORDER BY completed_at DESC",
                    (project_id,)
                )
            else:
                cur = conn.execute(
                    "SELECT run_id, project_id, output_path, completed_at, candidates_written "
                    "FROM memory_consolidation_runs WHERE status='completed' "
                    "ORDER BY completed_at DESC"
                )
            rows = [dict(r) for r in cur.fetchall()]
            conn.close()
            return rows
        except Exception as e:
            print(json.dumps({'error': f'DB query failed: {e}'}))
            sys.exit(1)


def is_promoted(output_path):
    """Return True if the sentinel .promoted file exists in the output dir."""
    sentinel = os.path.join(output_path, '.promoted')
    return os.path.exists(sentinel)


def get_promote_status(output_path):
    """
    Return the promotion status string for a run's output dir.
    'promoted' — .promoted sentinel exists (fully promoted, hidden from review)
    'partial'  — .partial sentinel exists (some files skipped/conflicted; retry eligible)
    'pending'  — neither sentinel exists (not yet promoted)
    """
    if os.path.exists(os.path.join(output_path, '.promoted')):
        return 'promoted'
    if os.path.exists(os.path.join(output_path, '.partial')):
        return 'partial'
    return 'pending'


def main():
    parser = argparse.ArgumentParser(
        description='List pending (unpromoted) cast memory dream output dirs.'
    )
    parser.add_argument('--project-id', help='Filter by project ID')
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH)')
    parser.add_argument('--json', action='store_true', dest='as_json',
                        help='Output as JSON array instead of table')
    args = parser.parse_args()

    db_path = args.db if args.db else get_db_path()

    if not os.path.exists(db_path):
        print(json.dumps({'error': f'cast.db not found: {db_path}'}))
        sys.exit(1)

    rows = fetch_completed_runs(db_path, args.project_id)

    pending = []
    for row in rows:
        if isinstance(row, dict):
            run_id = row.get('run_id', '')
            project_id = row.get('project_id', '')
            output_path = row.get('output_path', '')
            completed_at = row.get('completed_at', '')
            candidates_written = row.get('candidates_written', 0)
        else:
            # sqlite3.Row or tuple
            run_id = row[0]
            project_id = row[1]
            output_path = row[2]
            completed_at = row[3]
            candidates_written = row[4]

        if not output_path:
            continue
        if not os.path.isdir(output_path):
            continue

        promote_status = get_promote_status(output_path)
        # Hide fully-promoted runs; show pending and partial
        if promote_status == 'promoted':
            continue

        # Read manifest to get files_changed_count
        manifest_path = os.path.join(output_path, '_dream-manifest.json')
        files_changed_count = candidates_written or 0
        if os.path.exists(manifest_path):
            try:
                with open(manifest_path, 'r', encoding='utf-8') as f:
                    manifest = json.load(f)
                fw = manifest.get('files_written', [])
                # files_written may be list of objects or list of strings
                files_changed_count = len(fw)
            except Exception:
                pass

        pending.append({
            'run_id': run_id,
            'project_id': project_id,
            'output_path': output_path,
            'completed_at': completed_at,
            'files_changed_count': files_changed_count,
            'promote_status': promote_status,
        })

    if not pending:
        if args.as_json:
            print(json.dumps([]))
        else:
            print('No pending dream runs found.')
        sys.exit(0)

    if args.as_json:
        print(json.dumps(pending, indent=2))
        sys.exit(0)

    # Human-readable table
    col_widths = {
        'run_id': max(6, max(len(r['run_id']) for r in pending)),
        'project_id': max(10, max(len(r['project_id']) for r in pending)),
        'output_path': max(11, max(len(r['output_path']) for r in pending)),
        'completed_at': max(12, max(len(r['completed_at'] or '') for r in pending)),
        'files_changed_count': 13,
        'promote_status': 7,  # "pending" or "partial"
    }
    # Cap output_path display width
    col_widths['output_path'] = min(col_widths['output_path'], 60)

    header = (
        f"{'run_id':<{col_widths['run_id']}}  "
        f"{'project_id':<{col_widths['project_id']}}  "
        f"{'output_path':<{col_widths['output_path']}}  "
        f"{'completed_at':<{col_widths['completed_at']}}  "
        f"{'files_changed':>13}  "
        f"{'status':<{col_widths['promote_status']}}"
    )
    print(header)
    print('-' * len(header))

    for r in pending:
        op = r['output_path']
        if len(op) > col_widths['output_path']:
            op = '...' + op[-(col_widths['output_path'] - 3):]
        print(
            f"{r['run_id']:<{col_widths['run_id']}}  "
            f"{r['project_id']:<{col_widths['project_id']}}  "
            f"{op:<{col_widths['output_path']}}  "
            f"{(r['completed_at'] or ''):<{col_widths['completed_at']}}  "
            f"{r['files_changed_count']:>13}  "
            f"{r['promote_status']:<{col_widths['promote_status']}}"
        )

    print(f'\n{len(pending)} pending run(s). Use: cast memory dream promote --run-id <run_id>')
    print('(partial runs can be retried with --force)')
    sys.exit(0)


if __name__ == '__main__':
    main()
