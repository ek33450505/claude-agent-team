#!/bin/bash
# cast-memory-query.sh — Query agent memories from cast.db
#
# Usage:
#   cast-memory-query.sh "<query>" [--agent <name>] [--project <name>] [--limit 5] [--type <type>]
#
# Output: JSON array of results: [{id, agent, type, name, content, created_at}]
#
# Search strategy (in priority order):
#   1. Semantic: cosine similarity on embedding column (requires sqlite-vec + Ollama)
#   2. Full-text: LIKE search on content and name columns (always available)
#
# Exit: always 0

set -uo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
EMBED_MODEL="${CAST_EMBED_MODEL:-nomic-embed-text}"

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
# Attempt semantic search (requires sqlite-vec + Ollama)
# ---------------------------------------------------------------------------
SEMANTIC_SUCCESS=0

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  QUERY_EMBED_RESPONSE="$(curl -s --max-time 5 \
    "$OLLAMA_URL/api/embeddings" \
    -d "{\"model\":\"$EMBED_MODEL\",\"prompt\":$(printf '%s' "$QUERY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
    2>/dev/null || echo "")"

  if [ -n "$QUERY_EMBED_RESPONSE" ]; then
    SEMANTIC_RESULT="$(python3 - "$DB_PATH" "$QUERY_EMBED_RESPONSE" "$LIMIT" "$AGENT_FILTER" "$PROJECT_FILTER" "$TYPE_FILTER" <<'PYEOF'
import sys, sqlite3, json, struct, math

db_path = sys.argv[1]
embed_response_str = sys.argv[2]
limit = int(sys.argv[3])
agent_filter = sys.argv[4]
project_filter = sys.argv[5]
type_filter = sys.argv[6]

try:
    embed_data = json.loads(embed_response_str)
    query_vec = embed_data.get("embedding", [])
    if not query_vec:
        print("[]")
        sys.exit(0)
except Exception:
    print("[]")
    sys.exit(0)

def cosine_sim(a, b):
    dot = sum(x*y for x,y in zip(a,b))
    mag_a = math.sqrt(sum(x*x for x in a))
    mag_b = math.sqrt(sum(x*x for x in b))
    if mag_a == 0 or mag_b == 0:
        return 0.0
    return dot / (mag_a * mag_b)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

# Build WHERE
conditions = ["embedding IS NOT NULL"]
params = []
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
    f"SELECT id, agent, type, name, content, created_at, embedding FROM agent_memories WHERE {where_clause}",
    params
)
rows = cur.fetchall()
conn.close()

# Score by cosine similarity
scored = []
n = len(query_vec)
for row in rows:
    blob = row["embedding"]
    if not blob or len(blob) < 4:
        continue
    num_floats = len(blob) // 4
    row_vec = list(struct.unpack(f"{num_floats}f", blob[:num_floats*4]))
    # Truncate/pad to same dimension
    min_len = min(len(query_vec), len(row_vec))
    sim = cosine_sim(query_vec[:min_len], row_vec[:min_len])
    scored.append((sim, row))

scored.sort(key=lambda x: x[0], reverse=True)
results = []
for sim, row in scored[:limit]:
    results.append({
        "id": row["id"],
        "agent": row["agent"],
        "type": row["type"],
        "name": row["name"],
        "content": row["content"],
        "created_at": row["created_at"],
        "score": round(sim, 4)
    })

print(json.dumps(results, indent=2))
PYEOF
    2>/dev/null || echo "")"

    if [ -n "$SEMANTIC_RESULT" ] && [ "$SEMANTIC_RESULT" != "[]" ] && [ "$SEMANTIC_RESULT" != "" ]; then
      echo "$SEMANTIC_RESULT"
      SEMANTIC_SUCCESS=1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Fallback: full-text LIKE search
# ---------------------------------------------------------------------------
if [ "$SEMANTIC_SUCCESS" -eq 0 ]; then
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
fi

exit 0
