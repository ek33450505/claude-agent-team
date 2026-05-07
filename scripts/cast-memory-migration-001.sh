#!/usr/bin/env bash
# cast-memory-migration-001.sh - Idempotent migration to add last_verified column
set -euo pipefail

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
MIGRATIONS_LOG="${HOME}/.claude/logs/cast-migrations.log"

# Ensure log dir exists
mkdir -p "${HOME}/.claude/logs"

python3 - <<'PYEOF'
import os
import sqlite3
import datetime

db_path = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
log_path = os.environ.get('MIGRATIONS_LOG', os.path.expanduser('~/.claude/logs/cast-migrations.log'))

try:
    conn = sqlite3.connect(db_path, timeout=5)
    cur = conn.cursor()

    # Check if last_verified column exists
    cur.execute("PRAGMA table_info(agent_memories)")
    columns = {row[1]: row for row in cur.fetchall()}

    ts = datetime.datetime.utcnow().isoformat() + 'Z'

    if 'last_verified' not in columns:
        cur.execute("ALTER TABLE agent_memories ADD COLUMN last_verified TEXT")
        conn.commit()
        msg = f"[{ts}] [migration-001] Added column: last_verified"
        print("[migration] Added column: last_verified")
    else:
        msg = f"[{ts}] [migration-001] Column last_verified already exists"
        print("[migration] Already migrated")

    # Log the result
    try:
        with open(log_path, 'a') as f:
            f.write(msg + '\n')
    except Exception:
        pass

    conn.close()
except Exception as e:
    ts = datetime.datetime.utcnow().isoformat() + 'Z'
    msg = f"[{ts}] [migration-001] Error: {e}"
    print(f"[migration] Error: {e}", file=__import__('sys').stderr)
    try:
        with open(log_path, 'a') as f:
            f.write(msg + '\n')
    except Exception:
        pass
    raise
PYEOF
