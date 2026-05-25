#!/usr/bin/env python3
"""
cast-memory-dream-promote.py — Promote a dream output to canonical memory.

Steps:
  1. Load row from memory_consolidation_runs by run_id (must be status='completed')
  2. Read _dream-manifest.json from output_path
  3. Verify manifest has per-file pre_sha256 (required; exits with error if absent)
  4. For each file in files_written:
     - Compute current SHA256 of the target canonical path
     - If SHA matches stored pre_sha256 OR --force: atomically copy candidate → canonical
     - If SHA mismatches: skip, add to promotion_conflicts
  5. Update MEMORY.md from candidate's MEMORY.md (same SHA check)
  6. Write .promoted sentinel with timestamp + conflicts list
  7. Print promotion report JSON to stdout

Usage:
  cast-memory-dream-promote.py --run-id <id> [--db <path>] [--force] [--dry-run]
"""

import os
import sys
import json
import argparse
import hashlib
import shutil
import sqlite3
from datetime import datetime, timezone

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


def sha256_of_file(path):
    """Compute SHA256 of a file's content. Returns empty string if file not found."""
    try:
        with open(path, 'rb') as f:
            return hashlib.sha256(f.read()).hexdigest()
    except (OSError, FileNotFoundError):
        return ''


def fetch_run(db_path, run_id):
    """Fetch a row from memory_consolidation_runs by run_id."""
    if _CAST_DB_AVAILABLE:
        # cast_db.db_query(sql, params) — uses env-var DB path internally
        rows = db_query(
            "SELECT run_id, project_id, status, output_path, completed_at "
            "FROM memory_consolidation_runs WHERE run_id=? LIMIT 1",
            (run_id,)
        )
        if rows:
            r = rows[0]
            return dict(r)
        return None
    else:
        try:
            conn = sqlite3.connect(db_path, timeout=10)
            conn.row_factory = sqlite3.Row
            cur = conn.execute(
                "SELECT run_id, project_id, status, output_path, completed_at "
                "FROM memory_consolidation_runs WHERE run_id=? LIMIT 1",
                (run_id,)
            )
            row = cur.fetchone()
            conn.close()
            if row:
                return dict(row)
            return None
        except Exception as e:
            print(json.dumps({'error': f'DB query failed: {e}'}), file=sys.stderr)
            sys.exit(1)


def atomic_copy(src, dst):
    """
    Atomically copy src to dst using a .tmp intermediate.
    Raises OSError if the copy fails.
    """
    tmp = dst + '.tmp'
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
    except Exception:
        # Clean up temp file on failure
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
        raise


def main():
    parser = argparse.ArgumentParser(
        description='Promote a cast memory dream output to canonical.'
    )
    parser.add_argument('--run-id', required=True, metavar='ID',
                        help='run_id from memory_consolidation_runs')
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH)')
    parser.add_argument('--force', action='store_true',
                        help='Skip SHA precondition check and promote all files')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print what would happen without writing any files')
    args = parser.parse_args()

    db_path = args.db if args.db else get_db_path()

    if not os.path.exists(db_path):
        print(json.dumps({'error': f'cast.db not found: {db_path}'}))
        sys.exit(1)

    # Step 1: Load run row
    run = fetch_run(db_path, args.run_id)
    if not run:
        print(json.dumps({'error': f'run_id not found: {args.run_id}'}))
        sys.exit(1)

    if run.get('status') != 'completed':
        print(json.dumps({
            'error': f"run_id '{args.run_id}' has status '{run.get('status')}' — only 'completed' runs can be promoted"
        }))
        sys.exit(1)

    output_path = run.get('output_path', '')
    if not output_path or not os.path.isdir(output_path):
        print(json.dumps({'error': f'output_path does not exist: {output_path}'}))
        sys.exit(1)

    # Check if already promoted
    sentinel = os.path.join(output_path, '.promoted')
    if os.path.exists(sentinel):
        print(json.dumps({'error': f'Already promoted. Sentinel: {sentinel}'}))
        sys.exit(1)

    # Step 2: Read manifest
    manifest_path = os.path.join(output_path, '_dream-manifest.json')
    if not os.path.exists(manifest_path):
        print(json.dumps({'error': f'_dream-manifest.json not found at: {manifest_path}'}))
        sys.exit(1)

    try:
        with open(manifest_path, 'r', encoding='utf-8') as f:
            manifest = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(json.dumps({'error': f'Failed to read manifest: {e}'}))
        sys.exit(1)

    # Step 3: Validate manifest has per-file pre_sha256
    files_written = manifest.get('files_written', [])

    if files_written:
        # Check the shape of the first entry
        sample = files_written[0]
        if isinstance(sample, str):
            print(json.dumps({
                'error': (
                    'Manifest uses legacy string format for files_written — '
                    'per-file pre_sha256 is required for safe promotion. '
                    'Re-run the dream to generate an upgraded manifest.'
                )
            }))
            sys.exit(1)
        if not isinstance(sample, dict) or 'pre_sha256' not in sample:
            print(json.dumps({
                'error': (
                    f'files_written entries lack pre_sha256 field (shape: {type(sample).__name__}). '
                    'Re-run the dream to generate an upgraded manifest with pre_sha256.'
                )
            }))
            sys.exit(1)

    now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    promoted = []
    skipped = []
    promotion_conflicts = []

    # Step 4 + 5: Process each file_written entry
    for fw in files_written:
        name = fw.get('name', '')
        candidate_path = fw.get('candidate_path', '')
        canonical_path = fw.get('canonical_path', '')
        pre_sha256 = fw.get('pre_sha256', '')

        if not candidate_path or not canonical_path:
            skipped.append({
                'name': name,
                'reason': 'missing candidate_path or canonical_path in manifest entry',
            })
            continue

        if not os.path.exists(candidate_path):
            skipped.append({
                'name': name,
                'reason': f'candidate file not found: {candidate_path}',
            })
            continue

        # Compute current SHA of canonical path
        current_sha = sha256_of_file(canonical_path)

        sha_matches = (current_sha == pre_sha256) or (not pre_sha256)

        if not sha_matches and not args.force:
            promotion_conflicts.append({
                'name': name,
                'canonical_path': canonical_path,
                'expected_sha': pre_sha256,
                'current_sha': current_sha,
                'reason': 'canonical file was modified after dream started',
            })
            continue

        # Promote: atomically copy candidate → canonical
        if not args.dry_run:
            try:
                # Ensure parent directory exists
                parent = os.path.dirname(canonical_path)
                if parent and not os.path.exists(parent):
                    os.makedirs(parent, exist_ok=True)
                atomic_copy(candidate_path, canonical_path)
                promoted.append({
                    'name': name,
                    'canonical_path': canonical_path,
                    'sha_check': 'bypassed (--force)' if not sha_matches else 'passed',
                })
            except OSError as e:
                skipped.append({
                    'name': name,
                    'reason': f'write failed: {e}',
                })
        else:
            promoted.append({
                'name': name,
                'canonical_path': canonical_path,
                'sha_check': '[dry-run] bypassed (--force)' if not sha_matches else '[dry-run] would pass',
            })

    # Step 6: Write .promoted or .partial sentinel
    if not args.dry_run:
        fully_promoted = (
            len(promoted) == len(files_written)
            and len(promotion_conflicts) == 0
        )
        sentinel_data = {
            'promoted_at': now_iso,
            'run_id': args.run_id,
            'promoted_count': len(promoted),
            'skipped_count': len(skipped),
            'conflict_count': len(promotion_conflicts),
            'promotion_conflicts': promotion_conflicts,
        }
        if fully_promoted:
            write_sentinel_path = sentinel  # .promoted
        else:
            write_sentinel_path = os.path.join(output_path, '.partial')
        try:
            with open(write_sentinel_path, 'w', encoding='utf-8') as f:
                json.dump(sentinel_data, f, indent=2)
        except OSError as e:
            # Non-fatal: sentinel write failure doesn't roll back promotion
            print(json.dumps({
                'warning': f'Failed to write sentinel: {e}',
                'promoted': promoted,
            }), file=sys.stderr)

    # Step 7: Print promotion report
    report = {
        'run_id': args.run_id,
        'dry_run': args.dry_run,
        'force': args.force,
        'promoted_count': len(promoted),
        'skipped_count': len(skipped),
        'conflict_count': len(promotion_conflicts),
        'promoted': promoted,
        'skipped': skipped,
        'promotion_conflicts': promotion_conflicts,
        'promoted_at': now_iso,
    }
    print(json.dumps(report, indent=2))
    sys.exit(0 if not promotion_conflicts else 2)


if __name__ == '__main__':
    main()
