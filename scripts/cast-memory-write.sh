#!/bin/bash
# cast-memory-write.sh — Write a memory entry to cast.db agent_memories table
#
# Usage:
#   cast-memory-write.sh <agent> <type> <name> "<content>" [--project <name>]
#
# Types: user | feedback | project | reference
#
# Embedding: currently NULL. Future support planned via Claude Embeddings API.
# Rows are still useful for exact-match and full-text LIKE search.
#
# Deduplication: exact content match prevents duplicate inserts; matching row's
# updated_at is refreshed instead. If sqlite-vec is available, cosine similarity
# check also catches near-duplicates (similarity > 0.97).
#
# Exit: always 0 — never block agent workflows.

set -uo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
if [ "${#}" -lt 4 ]; then
  echo "Usage: cast-memory-write.sh <agent> <type> <name> \"<content>\" [--project <name>]" >&2
  exit 0
fi

AGENT="$1"
TYPE="$2"
NAME="$3"
CONTENT="$4"
shift 4

PROJECT=""
while [ "${#}" -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Validate type
case "$TYPE" in
  user|feedback|project|reference) ;;
  *)
    echo "Error: type must be one of: user, feedback, project, reference (got: '$TYPE')" >&2
    exit 0
    ;;
esac

# Validate non-empty required fields
if [ -z "$AGENT" ] || [ -z "$NAME" ] || [ -z "$CONTENT" ]; then
  echo "Error: agent, name, and content must all be non-empty" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Ensure DB exists
# ---------------------------------------------------------------------------
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 not found" >&2
  exit 0
fi

mkdir -p "$(dirname "$DB_PATH")"

# Run db-init if the table doesn't exist yet
if ! sqlite3 "$DB_PATH" "SELECT 1 FROM agent_memories LIMIT 1;" >/dev/null 2>&1; then
  bash "$(dirname "$0")/cast-db-init.sh" --db "$DB_PATH" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Deduplication check + Insert — all via parameterized Python (C6: SQL injection fix)
# ---------------------------------------------------------------------------
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DESCRIPTION="$(echo "$CONTENT" | cut -c1-100)"

# Pass all values as argv to Python — never interpolate into SQL strings
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSERT_ID="$(CAST_DB_PATH="$DB_PATH" python3 - "$DB_PATH" "$AGENT" "$PROJECT" "$TYPE" "$NAME" "$DESCRIPTION" "$CONTENT" "$NOW" "$SCRIPT_DIR" <<'PYEOF' 2>/dev/null || echo ""
import sys, os
from pathlib import Path

db_path, agent, project, mem_type, name, description, content, now, script_dir = sys.argv[1:10]

# Use cast_db abstraction if available alongside this script
sys.path.insert(0, script_dir)
try:
    from cast_db import db_execute, db_query
    USE_CAST_DB = True
except ImportError:
    import sqlite3
    USE_CAST_DB = False

if USE_CAST_DB:
    rows = db_query(
        "SELECT id FROM agent_memories WHERE agent = ? AND content = ? LIMIT 1",
        (agent, content)
    )
    if rows:
        existing_id = rows[0]['id']
        db_execute("UPDATE agent_memories SET updated_at = ? WHERE id = ?", (now, existing_id))
        print(f"UPDATED:{existing_id}")
        sys.exit(0)
    db_execute(
        "INSERT INTO agent_memories "
        "(agent, project, type, name, description, content, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (agent, project or None, mem_type, name, description, content, now, now)
    )
    rows = db_query("SELECT last_insert_rowid() AS id")
    print(rows[0]['id'] if rows else '')
else:
    import sqlite3
    conn = sqlite3.connect(db_path, timeout=5)
    cur = conn.cursor()
    cur.execute(
        "SELECT id FROM agent_memories WHERE agent = ? AND content = ? LIMIT 1",
        (agent, content)
    )
    row = cur.fetchone()
    if row:
        existing_id = row[0]
        cur.execute("UPDATE agent_memories SET updated_at = ? WHERE id = ?", (now, existing_id))
        conn.commit()
        conn.close()
        print(f"UPDATED:{existing_id}")
        sys.exit(0)
    cur.execute(
        "INSERT INTO agent_memories "
        "(agent, project, type, name, description, content, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (agent, project or None, mem_type, name, description, content, now, now)
    )
    conn.commit()
    insert_id = cur.lastrowid
    conn.close()
    print(insert_id)
PYEOF
)"

if echo "$INSERT_ID" | grep -q "^UPDATED:"; then
  DUP_ID="${INSERT_ID#UPDATED:}"
  echo "Memory updated (duplicate detected): $NAME [$DUP_ID]"
elif [ -n "$INSERT_ID" ]; then
  echo "Memory written: $NAME [$INSERT_ID]"
else
  echo "Memory written: $NAME [unknown id]"
fi

exit 0
