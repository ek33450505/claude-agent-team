#!/bin/bash
# cast-local-runner.sh — Execute a CAST agent task against a local Ollama model
#
# Usage: cast-local-runner.sh <agent_name> <model_name> <task>
#
# Reads:  ~/.claude/agents/<agent>.md (strips YAML frontmatter for system prompt)
# Writes: ~/.claude/cast.db agent_runs table (if DB exists)
# Output: agent response to stdout + structured Status block
#
# Error handling:
#   - Timeout (120s default): emits BLOCKED status
#   - VRAM/load errors: emits BLOCKED status with reason
#   - Missing agent file: emits NEEDS_CONTEXT status
#   - Always exits 0 (soft failure — caller decides whether to escalate)

set -euo pipefail

AGENT_NAME="${1:-}"
MODEL_NAME="${2:-}"
TASK="${3:-}"

AGENTS_DIR="${HOME}/.claude/agents"
CAST_DB="${HOME}/.claude/cast.db"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
REQUEST_TIMEOUT="${CAST_LOCAL_TIMEOUT:-120}"

# ── Validate inputs ──────────────────────────────────────────────────────────
if [[ -z "$AGENT_NAME" || -z "$MODEL_NAME" || -z "$TASK" ]]; then
  cat <<'EOF'
Status: BLOCKED
Reason: cast-local-runner.sh requires <agent_name> <model_name> <task>
EOF
  exit 0
fi

AGENT_FILE="${AGENTS_DIR}/${AGENT_NAME}.md"
if [[ ! -f "$AGENT_FILE" ]]; then
  cat <<EOF
Status: NEEDS_CONTEXT
Reason: Agent definition not found: ${AGENT_FILE}
EOF
  exit 0
fi

# ── Extract system prompt (strip YAML frontmatter) ───────────────────────────
SYSTEM_PROMPT=$(python3 - "$AGENT_FILE" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Strip YAML frontmatter between first two --- delimiters
stripped = re.sub(r'^---\n.*?\n---\n', '', content, count=1, flags=re.DOTALL).strip()

# Append mandatory CAST status block instruction
cast_instruction = """

---
MANDATORY OUTPUT FORMAT: End every response with a status block:

Status: DONE
(or DONE_WITH_CONCERNS, BLOCKED, NEEDS_CONTEXT)

If DONE_WITH_CONCERNS or BLOCKED, add:
Reason: <brief explanation>
"""

print(stripped + cast_instruction)
PYEOF
)

# ── Record start time ────────────────────────────────────────────────────────
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PROJECT="${CAST_PROJECT:-$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || echo 'unknown')}"

# ── Call Ollama ──────────────────────────────────────────────────────────────
RESPONSE=$(python3 - "$OLLAMA_URL" "$MODEL_NAME" "$SYSTEM_PROMPT" "$TASK" "$REQUEST_TIMEOUT" <<'PYEOF'
import sys, json, urllib.request, urllib.error

ollama_url  = sys.argv[1]
model       = sys.argv[2]
system_msg  = sys.argv[3]
user_task   = sys.argv[4]
timeout     = int(sys.argv[5])

payload = {
    "model": model,
    "messages": [
        {"role": "system", "content": system_msg},
        {"role": "user",   "content": user_task},
    ],
    "stream": False,
    "options": {
        "temperature": 0.2,
        "num_ctx": 32768,
    }
}

req = urllib.request.Request(
    f"{ollama_url}/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="POST"
)

try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode())
    content = data["choices"][0]["message"]["content"]
    print(content)
except urllib.error.URLError as e:
    if "timed out" in str(e).lower():
        print(f"Status: BLOCKED\nReason: Ollama request timed out after {timeout}s (model may still be loading)")
    else:
        print(f"Status: BLOCKED\nReason: Ollama connection error — {e}")
except Exception as e:
    # Surface VRAM / model loading errors
    err = str(e)
    if any(kw in err.lower() for kw in ["vram", "out of memory", "oom", "cuda"]):
        print(f"Status: BLOCKED\nReason: VRAM/memory error running {model} — {err}")
    else:
        print(f"Status: BLOCKED\nReason: Unexpected error — {err}")
PYEOF
)

ENDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Output response ──────────────────────────────────────────────────────────
echo "$RESPONSE"

# ── Parse status from response ───────────────────────────────────────────────
STATUS=$(echo "$RESPONSE" | grep -E '^Status:' | tail -1 | sed 's/^Status:[[:space:]]*//' | tr -d '\r' || echo "DONE")
TASK_SUMMARY=$(echo "$TASK" | head -c 200)

# ── Log to cast.db if it exists ──────────────────────────────────────────────
if [[ -f "$CAST_DB" ]] && command -v sqlite3 &>/dev/null; then
  python3 - "$CAST_DB" "$SESSION_ID" "$AGENT_NAME" "local:$MODEL_NAME" \
    "$STARTED_AT" "$ENDED_AT" "$STATUS" "$TASK_SUMMARY" "$PROJECT" <<'PYEOF' 2>/dev/null || true
import sys, sqlite3

db_path      = sys.argv[1]
session_id   = sys.argv[2]
agent        = sys.argv[3]
model        = sys.argv[4]
started_at   = sys.argv[5]
ended_at     = sys.argv[6]
status       = sys.argv[7]
task_summary = sys.argv[8]
project      = sys.argv[9]

# Local models are free — cost is always $0.00
cost_usd = 0.0

try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("""
        INSERT INTO agent_runs
          (session_id, agent, model, started_at, ended_at, status,
           input_tokens, output_tokens, cost_usd, task_summary, project)
        VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?)
    """, (session_id, agent, model, started_at, ended_at, status,
          cost_usd, task_summary, project))
    con.commit()
    con.close()
except Exception as e:
    # Never block the runner on DB errors
    import sys as _sys
    print(f"Warning: DB log failed — {e}", file=_sys.stderr)
PYEOF
fi

exit 0
