#!/usr/bin/env python3
"""
cast-db-log.py — Dual-write helper for CAST routing events.
Reads a JSON log entry from stdin and writes to:
  1. ~/.claude/routing-log.jsonl  (existing JSONL, via cast-log-append.py logic)
  2. ~/.claude/cast.db routing_events table (SQLite, via cast_db abstraction)

Replaces cast-log-append.py calls in route.sh during the 7a transition.
Preserves atomic JSONL append behavior (fcntl exclusive lock + rotation).
Errors are logged to ~/.claude/logs/db-write-errors.log — never blocks the hook pipeline.
"""
import sys, fcntl, os, json, argparse
from pathlib import Path

# Add scripts dir to path so cast_db is importable when run directly
sys.path.insert(0, str(Path(__file__).parent))
from cast_db import db_execute, _log_error

# -----------------------------------------------------------------------
# 0. Parse optional CLI arguments for agent_id/agent_type
# -----------------------------------------------------------------------
parser = argparse.ArgumentParser(description='CAST dual-write log helper')
parser.add_argument('--agent-id', default=None, help='Agent ID from hook event')
parser.add_argument('--agent-type', default=None, help='Agent type from hook event')
args, _unknown = parser.parse_known_args()

line = sys.stdin.read().strip()
if not line:
    sys.exit(0)

payload_preview = line[:200]

# -----------------------------------------------------------------------
# 1. Validate input JSON
# -----------------------------------------------------------------------
try:
    entry = json.loads(line)
except Exception:
    sys.exit(0)

# Merge CLI agent_id/agent_type into entry (CLI takes precedence)
if args.agent_id:
    entry['agent_id'] = args.agent_id
if args.agent_type:
    entry['agent_type'] = args.agent_type

# -----------------------------------------------------------------------
# 2. JSONL append (same behavior as cast-log-append.py)
# -----------------------------------------------------------------------
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
try:
    with open(log_path, 'a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(line + '\n')
        f.flush()
        try:
            if os.path.getsize(log_path) > 5 * 1024 * 1024:
                old2 = log_path + '.2'
                old1 = log_path + '.1'
                if os.path.exists(old2):
                    os.remove(old2)
                if os.path.exists(old1):
                    os.rename(old1, old2)
        except Exception as e:
            _log_error(f'JSONL rotation failed: {e}')
        # Lock released on close
except Exception as e:
    _log_error(f'JSONL append failed: {e}')

# -----------------------------------------------------------------------
# 3. SQLite write into routing_events (via cast_db abstraction)
# -----------------------------------------------------------------------
db_path = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
if not os.path.exists(db_path):
    sys.exit(0)

db_execute(
    '''INSERT INTO routing_events
       (session_id, timestamp, prompt_preview, action, matched_route,
        pattern, confidence, project)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
    (
        entry.get('session_id', 'unknown'),
        entry.get('timestamp', ''),
        entry.get('prompt_preview', entry.get('prompt_preview', ''))[:80],
        entry.get('action', ''),
        entry.get('matched_route'),
        entry.get('pattern'),
        entry.get('confidence'),
        entry.get('project'),
    )
)
