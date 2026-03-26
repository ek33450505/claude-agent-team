#!/usr/bin/env python3
"""
cast-db-log.py — Dual-write helper for CAST routing events.
Reads a JSON log entry from stdin and writes to:
  1. ~/.claude/routing-log.jsonl  (existing JSONL, via cast-log-append.py logic)
  2. ~/.claude/cast.db routing_events table (SQLite, new in Phase 7a)

Replaces cast-log-append.py calls in route.sh during the 7a transition.
Preserves atomic JSONL append behavior (fcntl exclusive lock + rotation).
Silent on any error — never blocks the hook pipeline.
"""
import sys, fcntl, os, json, sqlite3

line = sys.stdin.read().strip()
if not line:
    sys.exit(0)

# -----------------------------------------------------------------------
# 1. Validate input JSON
# -----------------------------------------------------------------------
try:
    entry = json.loads(line)
except Exception:
    sys.exit(0)

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
        except Exception:
            pass
        # Lock released on close
except Exception:
    pass

# -----------------------------------------------------------------------
# 3. SQLite write into routing_events
# -----------------------------------------------------------------------
db_path = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))
if not os.path.exists(db_path):
    sys.exit(0)

try:
    conn = sqlite3.connect(db_path, timeout=3)
    cur  = conn.cursor()
    cur.execute(
        '''INSERT INTO routing_events
           (session_id, timestamp, prompt_preview, action, matched_route,
            match_type, pattern, confidence, project)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        (
            entry.get('session_id', 'unknown'),
            entry.get('timestamp', ''),
            entry.get('prompt_preview', entry.get('prompt_preview', ''))[:80],
            entry.get('action', ''),
            entry.get('matched_route'),
            entry.get('match_type'),
            entry.get('pattern'),
            entry.get('confidence'),
            entry.get('project'),
        )
    )
    conn.commit()
    conn.close()
except Exception:
    pass
