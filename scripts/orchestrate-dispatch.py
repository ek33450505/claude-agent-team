#!/usr/bin/env python3
"""orchestrate-dispatch.py — CLI backend for the /orchestrate skill.

Subcommands:
  log-dispatch        Log backend + plan session to cast.db (Step 2)
  log-quality-gate    Log agent contract validation result (Step 4)
  recent-status       Return fresh status from agent status file (Step 4 fallback)

All subcommands exit 0 even on internal error — the orchestrate flow must never
be blocked by a DB write failure.
"""

import argparse
import datetime
import glob
import json
import os
import sys
from pathlib import Path


def _setup_cast_db() -> None:
    """Insert ~/.claude/scripts into sys.path so cast_db is importable."""
    scripts_dir = str(Path.home() / '.claude' / 'scripts')
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)


def _now_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _session_id(env_var: str = 'CAST_SESSION_ID') -> str:
    return (
        os.environ.get('CAST_SESSION_ID')
        or os.environ.get('CLAUDE_SESSION_ID')
        or 'unknown'
    )


# ---------------------------------------------------------------------------
# Subcommand: log-dispatch
# ---------------------------------------------------------------------------

def cmd_log_dispatch(backend: str, plan: str) -> None:
    """Write dispatch_decisions and plan_sessions rows (Step 2 of orchestrate)."""
    _setup_cast_db()
    try:
        from cast_db import db_write, db_execute  # type: ignore
    except Exception as e:
        sys.stderr.write(f'[orchestrate-dispatch] import cast_db failed: {e}\n')
        sys.exit(0)

    session_id = _session_id()
    now = _now_utc()

    try:
        db_execute('''
            CREATE TABLE IF NOT EXISTS dispatch_decisions (
                id               TEXT PRIMARY KEY,
                session_id       TEXT,
                timestamp        TEXT,
                dispatch_backend TEXT,
                plan_file        TEXT
            )
        ''')
        db_write('dispatch_decisions', {
            'id': os.urandom(8).hex(),
            'session_id': session_id,
            'timestamp': now,
            'dispatch_backend': backend,
            'plan_file': plan,
        })
    except Exception as e:
        sys.stderr.write(f'[orchestrate-dispatch] dispatch_decisions write failed: {e}\n')

    try:
        db_execute('''
            CREATE TABLE IF NOT EXISTS plan_sessions (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                plan_file  TEXT NOT NULL,
                started_at TEXT NOT NULL
            )
        ''')
        db_write('plan_sessions', {
            'session_id': session_id,
            'plan_file': plan,
            'started_at': now,
        })
    except Exception as e:
        sys.stderr.write(f'[orchestrate-dispatch] plan_sessions write failed: {e}\n')

    sys.exit(0)


# ---------------------------------------------------------------------------
# Subcommand: log-quality-gate
# ---------------------------------------------------------------------------

def _to_int(value: str, default: int = 0) -> int:
    """Parse value to int; return default on failure."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def cmd_log_quality_gate(
    batch_id: str,
    agent: str,
    status: str,
    contract_passed: str,
    retry_count: str,
) -> None:
    """Write a quality_gates row (Step 4 of orchestrate)."""
    _setup_cast_db()
    try:
        from cast_db import db_write, db_execute  # type: ignore
    except Exception as e:
        sys.stderr.write(f'[orchestrate-dispatch] import cast_db failed: {e}\n')
        sys.exit(0)

    session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')
    now = _now_utc()

    # contract_passed allows the special sentinel -1 (file-recovered status)
    cp_int = _to_int(contract_passed, default=0)
    batch_int = _to_int(batch_id, default=0)
    retry_int = _to_int(retry_count, default=0)

    # HONESTY-FIX: private CREATE TABLE formerly included batch_id, absent from the canonical
    # cast-db-init.sh quality_gates schema. When the table already existed (created by
    # cast-db-init.sh), CREATE IF NOT EXISTS was a no-op, then db_write silently returned False
    # because the column didn't exist. Fix: align with canonical schema — no batch_id.
    try:
        db_execute('''
            CREATE TABLE IF NOT EXISTS quality_gates (
                id               TEXT PRIMARY KEY,
                session_id       TEXT,
                agent_name       TEXT,
                timestamp        TEXT,
                status_line      TEXT,
                contract_passed  INTEGER,
                retry_count      INTEGER,
                gate_type        TEXT,  -- NULL here; no reader filters on gate_type (cast-dash/doctor query all rows)
                created_at       TEXT DEFAULT (datetime('now'))
            )
        ''')
        ok = db_write('quality_gates', {
            'id': os.urandom(8).hex(),
            'session_id': session_id,
            'agent_name': agent,
            'timestamp': now,
            'status_line': status,
            'contract_passed': cp_int,
            'retry_count': retry_int,
        })
        if not ok:
            sys.stderr.write('[orchestrate-dispatch] quality_gates write failed (db_write returned False)\n')
    except Exception as e:
        sys.stderr.write(f'[orchestrate-dispatch] quality_gates write failed: {e}\n')

    sys.exit(0)


# ---------------------------------------------------------------------------
# Subcommand: get-dispatch-backend
# ---------------------------------------------------------------------------

def cmd_get_dispatch_backend() -> None:
    """Read ~/.claude/config/cast-cli.json and print dispatch_backend (default: 'cast')."""
    config_path = Path.home() / '.claude' / 'config' / 'cast-cli.json'
    try:
        with open(config_path) as f:
            d = json.load(f)
        print(d.get('dispatch_backend', 'cast'))
    except Exception:
        print('cast')
    sys.exit(0)


# ---------------------------------------------------------------------------
# Subcommand: recent-status
# ---------------------------------------------------------------------------

def cmd_recent_status(agent: str, max_age: int) -> None:
    """Print the status field from the most recent fresh status file, or nothing."""
    pattern = str(Path.home() / '.claude' / 'agent-status' / f'{agent}-*.json')
    files = glob.glob(pattern)
    if not files:
        sys.exit(0)

    files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    most_recent = files[0]

    try:
        file_mtime = int(os.path.getmtime(most_recent))
    except OSError:
        sys.exit(0)

    now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    age = now - file_mtime
    if age > max_age:
        sys.exit(0)

    try:
        with open(most_recent) as fh:
            data = json.load(fh)
        status_value = data.get('status', '')
        if status_value:
            print(status_value)
    except Exception:
        pass  # unreadable file → print nothing

    sys.exit(0)


# ---------------------------------------------------------------------------
# Argument parsing + dispatch
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description='orchestrate-dispatch — CAST /orchestrate skill backend'
    )
    subparsers = parser.add_subparsers(dest='command', required=True)

    # log-dispatch
    p_ld = subparsers.add_parser('log-dispatch', help='Log dispatch_decisions + plan_sessions')
    p_ld.add_argument('--backend', required=True, help='dispatch_backend value')
    p_ld.add_argument('--plan', required=True, help='plan file path')

    # log-quality-gate
    p_qg = subparsers.add_parser('log-quality-gate', help='Log quality_gates row')
    p_qg.add_argument('--batch-id', required=True, dest='batch_id')
    p_qg.add_argument('--agent', required=True)
    p_qg.add_argument('--status', required=True)
    p_qg.add_argument('--contract-passed', required=True, dest='contract_passed')
    p_qg.add_argument('--retry-count', required=True, dest='retry_count')

    # get-dispatch-backend
    subparsers.add_parser(
        'get-dispatch-backend',
        help='Print dispatch_backend from cast-cli.json (default: cast)',
    )

    # recent-status
    p_rs = subparsers.add_parser('recent-status', help='Return fresh status from status file')
    p_rs.add_argument('--agent', required=True)
    p_rs.add_argument('--max-age', type=int, default=300, dest='max_age',
                      help='Maximum file age in seconds (default: 300)')

    args = parser.parse_args()

    try:
        if args.command == 'get-dispatch-backend':
            cmd_get_dispatch_backend()
        elif args.command == 'log-dispatch':
            cmd_log_dispatch(args.backend, args.plan)
        elif args.command == 'log-quality-gate':
            cmd_log_quality_gate(
                args.batch_id,
                args.agent,
                args.status,
                args.contract_passed,
                args.retry_count,
            )
        elif args.command == 'recent-status':
            cmd_recent_status(args.agent, args.max_age)
    except Exception as e:
        sys.stderr.write(f'[orchestrate-dispatch] unhandled error: {e}\n')
        sys.exit(0)


if __name__ == '__main__':
    main()
