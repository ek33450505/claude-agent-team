#!/bin/bash
# cast-embed-agents.sh — Pre-compute Ollama embeddings for all routable agents
# Stores results in ~/.claude/config/agent-embeddings.json
#
# Usage: cast-embed-agents.sh
# Exits 0 always — fails gracefully if Ollama is not running.

set -euo pipefail

ROUTING_TABLE="${HOME}/.claude/config/routing-table.json"
AGENTS_DIR="${HOME}/.claude/agents"
OUTPUT_FILE="${HOME}/.claude/config/agent-embeddings.json"
OLLAMA_URL="http://localhost:11434"
EMBED_MODEL="nomic-embed-text"

# Check Ollama is running
if ! curl -sf "${OLLAMA_URL}" > /dev/null 2>&1; then
  echo "Ollama not running — skipping embedding generation"
  exit 0
fi

if [ ! -f "$ROUTING_TABLE" ]; then
  echo "Error: routing-table.json not found at ${ROUTING_TABLE}" >&2
  exit 1
fi

if [ ! -d "$AGENTS_DIR" ]; then
  echo "Error: agents directory not found at ${AGENTS_DIR}" >&2
  exit 1
fi

python3 - "$ROUTING_TABLE" "$AGENTS_DIR" "$OUTPUT_FILE" "$OLLAMA_URL" "$EMBED_MODEL" <<'PYEOF'
import sys
import json
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone

routing_table_path = sys.argv[1]
agents_dir = sys.argv[2]
output_path = sys.argv[3]
ollama_url = sys.argv[4]
embed_model = sys.argv[5]

# Read routing table, extract unique agent names
with open(routing_table_path) as f:
    routing_data = json.load(f)

agents_set = set()
# routing-table.json may be {routes: [...]} or a list or dict with 'agent' keys
def extract_agents(obj):
    if isinstance(obj, list):
        for item in obj:
            extract_agents(item)
    elif isinstance(obj, dict):
        if 'agent' in obj and isinstance(obj['agent'], str):
            agents_set.add(obj['agent'])
        for v in obj.values():
            extract_agents(v)

extract_agents(routing_data)

if not agents_set:
    print("No agents found in routing-table.json", file=sys.stderr)
    sys.exit(0)

def get_agent_description(agent_name):
    """Extract description: from agent frontmatter."""
    agent_file = os.path.join(agents_dir, f"{agent_name}.md")
    if not os.path.exists(agent_file):
        return None
    try:
        with open(agent_file) as f:
            lines = []
            for i, line in enumerate(f):
                lines.append(line)
                if i >= 15:
                    break
        for line in lines:
            line = line.strip()
            if line.lower().startswith('description:'):
                return line[len('description:'):].strip()
    except Exception:
        pass
    return None

def embed_text(text):
    """POST to Ollama embeddings API, return embedding list."""
    payload = json.dumps({"model": embed_model, "prompt": text}).encode()
    req = urllib.request.Request(
        f"{ollama_url}/api/embeddings",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.loads(resp.read().decode())
    return result["embedding"]

results = []
skipped = []

for agent_name in sorted(agents_set):
    description = get_agent_description(agent_name)
    if description is None:
        skipped.append(agent_name)
        continue
    embed_text_str = f"{agent_name}: {description}"
    try:
        embedding = embed_text(embed_text_str)
        results.append({
            "agent": agent_name,
            "text": embed_text_str,
            "embedding": embedding,
        })
    except Exception as e:
        print(f"Warning: failed to embed agent '{agent_name}': {e}", file=sys.stderr)
        skipped.append(agent_name)
        continue

# Write output
os.makedirs(os.path.dirname(output_path), exist_ok=True)
output = {
    "model": embed_model,
    "generated": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "agents": results,
}
with open(output_path, 'w') as f:
    json.dump(output, f, indent=2)

if skipped:
    print(f"Skipped {len(skipped)} agents (no agent file or embed failed): {', '.join(skipped)}", file=sys.stderr)

print(f"Generated embeddings for {len(results)} agents")
PYEOF
