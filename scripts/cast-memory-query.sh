#!/bin/bash
# cast-memory-query.sh — Query agent memories from cast.db
#
# Usage:
#   cast-memory-query.sh "<query>" [--agent <name>] [--project <name>] [--limit 5] [--type <type>]
#
# Output: JSON array of results: [{id, agent, type, name, content, created_at}]
#
# Search strategy:
#   Full-text: LIKE search on content and name columns (always available)
#   # Embeddings disabled — future: replace with Claude Embeddings API
#
# Exit: always 0

set -uo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
if [ "${#}" -lt 1 ] || [ "${1:-}" = "" ]; then
  echo "[]"
  exit 0
fi

QUERY="$1"
shift

AGENT_FILTER=""
PROJECT_FILTER=""
TYPE_FILTER=""
LIMIT=5

while [ "${#}" -gt 0 ]; do
  case "$1" in
    --agent)
      AGENT_FILTER="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT_FILTER="${2:-}"
      shift 2
      ;;
    --type)
      TYPE_FILTER="${2:-}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-5}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "[]"
  exit 0
fi

if ! sqlite3 "$DB_PATH" "SELECT 1 FROM agent_memories LIMIT 1;" >/dev/null 2>&1; then
  echo "[]"
  exit 0
fi

# ---------------------------------------------------------------------------
# Build WHERE clause fragments
# ---------------------------------------------------------------------------
build_where_clauses() {
  local clauses=()
  if [ -n "$AGENT_FILTER" ]; then
    clauses+=("agent='$(echo "$AGENT_FILTER" | sed "s/'/''/g")'")
  fi
  if [ -n "$PROJECT_FILTER" ]; then
    clauses+=("project='$(echo "$PROJECT_FILTER" | sed "s/'/''/g")'")
  fi
  if [ -n "$TYPE_FILTER" ]; then
    clauses+=("type='$(echo "$TYPE_FILTER" | sed "s/'/''/g")'")
  fi
  if [ "${#clauses[@]}" -gt 0 ]; then
    local IFS=" AND "
    echo "AND ${clauses[*]}"
  fi
}

EXTRA_WHERE="$(build_where_clauses)"

# ---------------------------------------------------------------------------
# Full-text LIKE search
# ---------------------------------------------------------------------------
QUERY_ESC="$(echo "$QUERY" | sed "s/'/''/g")"

python3 - "$DB_PATH" "$QUERY_ESC" "$LIMIT" "$AGENT_FILTER" "$PROJECT_FILTER" "$TYPE_FILTER" <<'PYEOF' 2>/dev/null || echo "[]"
import sys, sqlite3, json

db_path, query, limit_str, agent_filter, project_filter, type_filter = sys.argv[1:7]
limit = int(limit_str)

try:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    conditions = ["(content LIKE ? OR name LIKE ?)"]
    params = [f"%{query}%", f"%{query}%"]
    if agent_filter:
        conditions.append("agent = ?")
        params.append(agent_filter)
    if project_filter:
        conditions.append("project = ?")
        params.append(project_filter)
    if type_filter:
        conditions.append("type = ?")
        params.append(type_filter)

    where_clause = " AND ".join(conditions)
    cur.execute(
        f"SELECT id, agent, type, name, content, created_at FROM agent_memories WHERE {where_clause} LIMIT ?",
        params + [limit]
    )
    rows = cur.fetchall()
    conn.close()

    results = [
        {
            "id": row["id"],
            "agent": row["agent"],
            "type": row["type"],
            "name": row["name"],
            "content": row["content"],
            "created_at": row["created_at"]
        }
        for row in rows
    ]
    print(json.dumps(results, indent=2))
except Exception as e:
    print("[]")
PYEOF

exit 0
