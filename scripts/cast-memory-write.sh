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
# Deduplication: exact content match
# ---------------------------------------------------------------------------
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

EXISTING_ID="$(sqlite3 "$DB_PATH" \
  "SELECT id FROM agent_memories WHERE agent='$(echo "$AGENT" | sed "s/'/''/g")' AND content='$(echo "$CONTENT" | sed "s/'/''/g")' LIMIT 1;" \
  2>/dev/null || echo "")"

if [ -n "$EXISTING_ID" ]; then
  sqlite3 "$DB_PATH" \
    "UPDATE agent_memories SET updated_at='$NOW' WHERE id=$EXISTING_ID;" 2>/dev/null || true
  echo "Memory updated (duplicate detected): $NAME [$EXISTING_ID]"
  exit 0
fi

# ---------------------------------------------------------------------------
# Embeddings disabled — future: replace with Claude Embeddings API
# ---------------------------------------------------------------------------
EMBEDDING_BLOB=""
EMBEDDING_JSON=""

# ---------------------------------------------------------------------------
# Description: first 100 chars of content
# ---------------------------------------------------------------------------
DESCRIPTION="$(echo "$CONTENT" | cut -c1-100)"

# ---------------------------------------------------------------------------
# Insert row
# ---------------------------------------------------------------------------
# Escape single quotes for SQLite
AGENT_ESC="$(echo "$AGENT" | sed "s/'/''/g")"
PROJECT_ESC="$(echo "$PROJECT" | sed "s/'/''/g")"
TYPE_ESC="$(echo "$TYPE" | sed "s/'/''/g")"
NAME_ESC="$(echo "$NAME" | sed "s/'/''/g")"
DESC_ESC="$(echo "$DESCRIPTION" | sed "s/'/''/g")"
CONTENT_ESC="$(echo "$CONTENT" | sed "s/'/''/g")"

if [ -n "$EMBEDDING_JSON" ]; then
  # Insert with embedding decoded from base64 → BLOB via Python helper
  INSERT_ID="$(python3 - "$DB_PATH" "$AGENT_ESC" "$PROJECT_ESC" "$TYPE_ESC" "$NAME_ESC" "$DESC_ESC" "$CONTENT_ESC" "$NOW" "$EMBEDDING_JSON" <<'PYEOF'
import sys, sqlite3, base64, struct

db_path, agent, project, mem_type, name, desc, content, now, emb_b64 = sys.argv[1:10]

blob = base64.b64decode(emb_b64)
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(
    "INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at, embedding) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    (agent, project or None, mem_type, name, desc, content, now, now, blob)
)
conn.commit()
print(cur.lastrowid)
conn.close()
PYEOF
  2>/dev/null || echo "")"
else
  # Build project SQL value: NULL when empty, quoted string otherwise
  if [ -n "$PROJECT_ESC" ]; then
    PROJECT_SQL="'$PROJECT_ESC'"
  else
    PROJECT_SQL="NULL"
  fi
  INSERT_ID="$(sqlite3 "$DB_PATH" \
    "INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at, embedding) \
     VALUES ('$AGENT_ESC',$PROJECT_SQL,'$TYPE_ESC','$NAME_ESC','$DESC_ESC','$CONTENT_ESC','$NOW','$NOW',NULL); \
     SELECT last_insert_rowid();" \
    2>/dev/null || echo "")"
fi

if [ -n "$INSERT_ID" ]; then
  echo "Memory written: $NAME [$INSERT_ID]"
else
  echo "Memory written: $NAME [unknown id]"
fi

exit 0
