#!/bin/bash
# cast-ollama-health.sh — Ollama availability check with 5-minute model cache
#
# Usage: cast-ollama-health.sh
# Output: exits 0 if Ollama is reachable; exits 1 if not
# Side effect: writes/refreshes ~/.claude/config/ollama-available.json
#
# Guards:
#   - Skips refresh if cache is < 5 minutes old
#   - Never blocks the session; all errors are soft

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
CACHE_FILE="${HOME}/.claude/config/ollama-available.json"
CACHE_TTL=300  # 5 minutes

# Skip re-check if cache is fresh
if [[ -f "$CACHE_FILE" ]]; then
  MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$(( NOW - MTIME ))
  if [[ $AGE -lt $CACHE_TTL ]]; then
    # Cache is fresh — read available flag and exit accordingly
    AVAIL=$(python3 -c "import json,sys; d=json.load(open('$CACHE_FILE')); print(d.get('available','false'))" 2>/dev/null || echo "false")
    [[ "$AVAIL" == "True" || "$AVAIL" == "true" ]] && exit 0 || exit 1
  fi
fi

# Probe Ollama
OLLAMA_REACHABLE=false
MODELS_JSON="[]"

if curl -sf --max-time 3 "${OLLAMA_URL}/api/tags" > /tmp/cast-ollama-tags.json 2>/dev/null; then
  OLLAMA_REACHABLE=true
  MODELS_JSON=$(python3 - /tmp/cast-ollama-tags.json <<'PYEOF'
import sys, json

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    models = [m["name"] for m in data.get("models", [])]
    print(json.dumps(models))
except Exception:
    print("[]")
PYEOF
)
fi

# Write cache
mkdir -p "$(dirname "$CACHE_FILE")"
python3 - "$OLLAMA_URL" "$OLLAMA_REACHABLE" "$MODELS_JSON" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

ollama_url     = sys.argv[1]
available      = sys.argv[2] == "true"
models_raw     = sys.argv[3]

try:
    models = json.loads(models_raw)
except Exception:
    models = []

# Build a fast-lookup set: strip tag suffix for canonical name matching
# e.g. "qwen3:8b" stays "qwen3:8b"; "devstral:24b-small-2505-q4_K_M" → keep full name too
canonical = {}
for m in models:
    base = m.split(":")[0] if ":" in m else m
    canonical[m] = True          # exact match
    canonical[base] = True       # prefix match (e.g. "qwen3")

cache = {
    "available": available,
    "ollama_url": ollama_url,
    "checked_at": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "models": models,
    "model_index": canonical,
}

import os
cache_file = os.path.expanduser("~/.claude/config/ollama-available.json")
with open(cache_file, "w") as f:
    json.dump(cache, f, indent=2)

if available:
    print(f"Ollama reachable — {len(models)} model(s) cached")
else:
    print("Ollama not reachable — cache updated (available=false)")
PYEOF

rm -f /tmp/cast-ollama-tags.json

[[ "$OLLAMA_REACHABLE" == "true" ]] && exit 0 || exit 1
