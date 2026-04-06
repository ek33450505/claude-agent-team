#!/usr/bin/env python3
"""
cast-memory-validate.py — Staleness validation for CAST agent memories.

Checks memories for age staleness, missing file references, and missing symbols.
Outputs a JSON report sorted by staleness_score descending.

Usage:
  cast-memory-validate.py [--db <path>] [--age-days N]
                          [--check]         # report only (default)
                          [--validate]      # update last_validated_at for non-stale
                          [--archive-stale] # set importance=0 for stale memories

Exit: 0 always (exit 1 only on DB connection failure).
"""

import os
import sys
import json
import re
import argparse
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

REPO_DIR = os.path.expanduser('~/Projects/personal/claude-agent-team')
SYMBOL_REGEX = re.compile(r'`(\w{4,})`')
PATH_REGEX = re.compile(r'(?:^|[\s(\'"](/[^\s\'")\]]+))', re.MULTILINE)


def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def check_schema(conn):
    """Warn if last_validated_at column is missing."""
    rows = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
    cols = {row[1] for row in rows}
    if 'last_validated_at' not in cols:
        print("WARNING: last_validated_at column not present. Run cast-memory-schema-v3.py first.",
              file=sys.stderr)
        return False
    return True


def check_age(row, age_days, has_validated_col):
    """Return (age_factor, reason_str or None)."""
    now = datetime.now(timezone.utc)
    threshold = now - timedelta(days=age_days)

    created_at_str = row.get('created_at')
    last_validated_str = row.get('last_validated_at') if has_validated_col else None

    def parse_dt(s):
        """Parse datetime string to tz-aware UTC datetime. Handles naive timestamps."""
        if not s:
            return None
        try:
            dt = datetime.fromisoformat(s.replace('Z', '+00:00'))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except Exception:
            return None

    # Determine relevant date to check
    if last_validated_str:
        check_date = parse_dt(last_validated_str)
        if check_date is not None:
            if check_date < threshold:
                days_ago = (now - check_date).days
                return 1.0, f"age: {days_ago} days since last validation"
            return 0.0, None

    if created_at_str:
        created_at = parse_dt(created_at_str)
        if created_at is not None:
            if last_validated_str is None and created_at < threshold:
                days_ago = (now - created_at).days
                return 1.0, f"age: {days_ago} days old, never validated"
            return 0.0, None

    return 0.0, None


def check_file_refs(content):
    """Return (missing_file_factor, reason_list)."""
    if not content:
        return 0.0, []

    matches = PATH_REGEX.findall(content)
    paths = list(dict.fromkeys(m for m in matches if m))  # deduplicate, preserve order

    if not paths:
        return 0.0, []

    missing = []
    for path in paths:
        if not os.path.exists(path):
            missing.append(f"missing file: {path}")

    factor = min(1.0, len(missing) / max(1, len(paths)))
    return factor, missing


def check_symbols(content):
    """Return (missing_symbol_factor, reason_list). Caps at 3 symbols."""
    if not content:
        return 0.0, []

    symbols = list(dict.fromkeys(SYMBOL_REGEX.findall(content)))[:3]

    if not symbols:
        return 0.0, []

    missing = []
    for sym in symbols:
        try:
            result = subprocess.run(
                ['grep', '-r',
                 '--include=*.py', '--include=*.sh', '--include=*.js',
                 '-l', sym,
                 REPO_DIR],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0 or not result.stdout.strip():
                missing.append(f"missing symbol: `{sym}` not found in repo")
        except Exception:
            # On error, don't penalize — skip this symbol
            pass

    factor = min(1.0, len(missing) / max(1, len(symbols)))
    return factor, missing


def analyze_memory(row, age_days, has_validated_col):
    """Compute staleness score and build report entry for one memory row."""
    content = row.get('content', '') or ''

    age_factor, age_reason = check_age(row, age_days, has_validated_col)
    files_factor, file_reasons = check_file_refs(content)
    syms_factor, sym_reasons = check_symbols(content)

    score = round(0.5 * age_factor + 0.3 * files_factor + 0.2 * syms_factor, 4)

    reasons = []
    if age_reason:
        reasons.append(age_reason)
    reasons.extend(file_reasons)
    reasons.extend(sym_reasons)

    if score < 0.3:
        recommendation = 'keep'
    elif score <= 0.5:
        recommendation = 'review'
    else:
        recommendation = 'archive'

    return {
        'id': row.get('id'),
        'name': row.get('name', ''),
        'agent': row.get('agent', ''),
        'staleness_score': score,
        'reasons': reasons,
        'recommendation': recommendation
    }


def load_memories(conn):
    """Return list of dicts from agent_memories."""
    # Get column names
    col_info = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
    col_names = [r[1] for r in col_info]

    rows = conn.execute("SELECT * FROM agent_memories").fetchall()
    return [dict(zip(col_names, row)) for row in rows]


def main():
    parser = argparse.ArgumentParser(
        description='Validate CAST agent memories for staleness.'
    )
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH)')
    parser.add_argument('--age-days', type=int, default=30, metavar='N',
                        help='Age threshold in days (default: 30)')
    parser.add_argument('--check', action='store_true',
                        help='Report only (default behavior)')
    parser.add_argument('--validate', action='store_true',
                        help='Update last_validated_at for non-stale memories (score < 0.5)')
    parser.add_argument('--archive-stale', action='store_true',
                        help='Set importance=0.0 for stale memories (score >= 0.5)')
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
        has_validated_col = check_schema(conn)
        memories = load_memories(conn)

        report = []
        for mem in memories:
            entry = analyze_memory(mem, args.age_days, has_validated_col)
            report.append(entry)

        report.sort(key=lambda x: x['staleness_score'], reverse=True)

        # Print JSON report first (all modes)
        print(json.dumps(report, indent=2))

        now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

        if args.validate:
            # Update last_validated_at for memories with score < 0.5
            non_stale_ids = [e['id'] for e in report if e['staleness_score'] < 0.5 and e['id'] is not None]
            count = 0
            for mem_id in non_stale_ids:
                if has_validated_col:
                    conn.execute(
                        "UPDATE agent_memories SET last_validated_at = ? WHERE id = ?",
                        (now_str, mem_id)
                    )
                    count += 1
            conn.commit()
            print(f"Validated {count} memories.", file=sys.stderr)

        if args.archive_stale:
            # Set importance=0.0 for memories with score >= 0.5
            stale_ids = [e['id'] for e in report if e['staleness_score'] >= 0.5 and e['id'] is not None]
            count = 0
            for mem_id in stale_ids:
                conn.execute(
                    "UPDATE agent_memories SET importance = 0.0 WHERE id = ?",
                    (mem_id,)
                )
                count += 1
            conn.commit()
            print(f"Archived {count} stale memories.", file=sys.stderr)

        conn.close()
        sys.exit(0)

    except sqlite3.Error as e:
        print(f"ERROR: Validation failed: {e}", file=sys.stderr)
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
