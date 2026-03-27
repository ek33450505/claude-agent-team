#!/bin/bash
# cast-semantic-route.sh — Cosine-similarity semantic routing via Ollama
# Given a prompt string, prints the best-matching agent name to stdout (or nothing).
#
# Usage: cast-semantic-route.sh "<prompt text>"
# Output: agent name or empty string
# Exit: always 0 (graceful fallback)

set -euo pipefail

PROMPT_TEXT="${1:-}"

if [[ -z "$PROMPT_TEXT" ]]; then
  exit 0
fi

python3 - "$PROMPT_TEXT" "${SEMANTIC_THRESHOLD:-0.72}" "${HOME}/.claude/config/agent-embeddings.json" "${OLLAMA_URL:-http://localhost:11434}" "nomic-embed-text-v2-moe" <<'PYEOF' 2>/dev/null || exit 0
import sys
import json
import os
import urllib.request
import urllib.error

prompt_text = sys.argv[1]
threshold   = float(sys.argv[2])
embed_file  = sys.argv[3]
ollama_url  = sys.argv[4]
embed_model = sys.argv[5]

def cosine_similarity(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    mag_a = sum(x * x for x in a) ** 0.5
    mag_b = sum(x * x for x in b) ** 0.5
    if mag_a == 0 or mag_b == 0:
        return 0.0
    return dot / (mag_a * mag_b)

def embed_text(text):
    payload = json.dumps({"model": embed_model, "prompt": text}).encode()
    req = urllib.request.Request(
        f"{ollama_url}/api/embeddings",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        result = json.loads(resp.read().decode())
    return result["embedding"]

# Step 1: check embeddings file exists
if not os.path.exists(embed_file):
    sys.exit(0)

# Step 2: check Ollama is running (1s timeout)
try:
    req = urllib.request.Request(ollama_url, method="GET")
    urllib.request.urlopen(req, timeout=1)
except Exception:
    sys.exit(0)

# Step 3: load agent embeddings
with open(embed_file) as f:
    data = json.load(f)

agents = data.get("agents", [])
if not agents:
    sys.exit(0)

# Step 4: embed the input prompt
prompt_embedding = embed_text(prompt_text)

# Step 5: find best-matching agent via cosine similarity
best_agent = None
best_score = -1.0

for entry in agents:
    stored = entry.get("embedding")
    if not stored:
        continue
    score = cosine_similarity(prompt_embedding, stored)
    if score > best_score:
        best_score = score
        best_agent = entry.get("agent", "")

# Step 6: threshold check
if best_score > threshold and best_agent:
    print(best_agent)

sys.exit(0)
PYEOF

exit 0
