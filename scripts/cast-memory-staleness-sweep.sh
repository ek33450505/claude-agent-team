#!/usr/bin/env bash
# cast-memory-staleness-sweep.sh - Verify memory entries and update confidence
set -euo pipefail

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"
MAX_ENTRIES=20
ALL_FLAG=0

# Parse args
while [ "${#}" -gt 0 ]; do
  case "$1" in
    --all) ALL_FLAG=1; shift ;;
    *) shift ;;
  esac
done

# If --all, don't limit
[ "$ALL_FLAG" -eq 1 ] && MAX_ENTRIES=999999

python3 - "$CAST_DB_PATH" "$MAX_ENTRIES" "$CAST_SCRIPTS_DIR" <<'PYEOF'
import os
import sys
import sqlite3
import json
import subprocess
import datetime

db_path = sys.argv[1]
max_entries = int(sys.argv[2])
scripts_dir = sys.argv[3]

try:
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    # Query stale entries (null last_verified OR older than 30 days)
    cur.execute("""
        SELECT id, name, content
        FROM agent_memories
        WHERE last_verified IS NULL OR last_verified < datetime('now', '-30 days')
        LIMIT ?
    """, (max_entries,))
    rows = cur.fetchall()

    if not rows:
        print("No stale entries found.")
        sys.exit(0)

    verified_count = 0
    stale_count = 0

    for row in rows:
        entry_id = row['id']
        entry_name = row['name']
        content = row['content'] or ''

        # Call verifier
        try:
            result = subprocess.run(
                ['python3', os.path.join(scripts_dir, 'cast_memory_verifier.py')],
                input=content,
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode != 0:
                # Verifier failed — mark as stale
                confidence_delta = -0.2
            else:
                # Parse result JSON
                try:
                    verif = json.loads(result.stdout)
                    confidence_delta = verif.get('confidence_delta', 0)
                except json.JSONDecodeError:
                    confidence_delta = -0.2
        except Exception as e:
            # Subprocess failed
            confidence_delta = -0.2

        # Update database: set new confidence and last_verified
        # Confidence: old + delta, clamped to [0.0, 1.0]
        cur.execute("SELECT confidence FROM agent_memories WHERE id = ?", (entry_id,))
        old_confidence = cur.fetchone()[0] or 1.0
        new_confidence = max(0.0, min(1.0, old_confidence + confidence_delta))

        cur.execute("""
            UPDATE agent_memories
            SET confidence = ?, last_verified = datetime('now')
            WHERE id = ?
        """, (new_confidence, entry_id))

        # Determine status
        is_stale = new_confidence < 0.4
        status_str = "STALE" if is_stale else "VERIFIED"
        print(f"[{status_str}] {entry_name} confidence: {new_confidence:.1f}")

        if is_stale:
            stale_count += 1
        else:
            verified_count += 1

    conn.commit()
    conn.close()

    print(f"\nSweep complete: {verified_count} verified, {stale_count} stale")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
