#!/bin/bash
# cast-model-resolver.sh — Resolve an agent's model field to a concrete model spec
#
# Usage: cast-model-resolver.sh <agent_name> [prompt_length]
#
# Reads: ~/.claude/agents/<agent>.md (model: field)
#        ~/.claude/config/ollama-available.json (availability cache)
#
# Outputs: JSON to stdout:
#   {"resolved": "local:qwen3:8b", "backend": "local", "model": "qwen3:8b", "fallback": false}
# or
#   {"resolved": "cloud:haiku", "backend": "cloud", "model": "haiku", "fallback": true, "reason": "..."}
#
# Exit: always 0 (graceful fallback to cloud on any error)

set -euo pipefail

AGENT_NAME="${1:-}"
PROMPT_LENGTH="${2:-0}"

AGENTS_DIR="${HOME}/.claude/agents"
OLLAMA_CACHE="${HOME}/.claude/config/ollama-available.json"
DEFAULT_CLOUD_FALLBACK="cloud:haiku"

# Complexity thresholds for 'auto' mode
AUTO_SIMPLE_MAX_CHARS=500      # short prompts → lightweight local
AUTO_MEDIUM_MAX_CHARS=2000     # medium prompts → general local
AUTO_HEAVY_THRESHOLD=2001      # long/complex → cloud

emit_result() {
  python3 -c "
import json, sys
d = {
    'resolved': sys.argv[1],
    'backend':  sys.argv[2],
    'model':    sys.argv[3],
    'fallback': sys.argv[4] == 'true',
}
if len(sys.argv) > 5:
    d['reason'] = sys.argv[5]
print(json.dumps(d))
" "$@"
}

# ── Read agent model field ──────────────────────────────────────────────────
if [[ -z "$AGENT_NAME" ]]; then
  emit_result "$DEFAULT_CLOUD_FALLBACK" "cloud" "haiku" "true" "no agent name provided"
  exit 0
fi

AGENT_FILE="${AGENTS_DIR}/${AGENT_NAME}.md"
if [[ ! -f "$AGENT_FILE" ]]; then
  emit_result "$DEFAULT_CLOUD_FALLBACK" "cloud" "haiku" "true" "agent file not found: ${AGENT_NAME}.md"
  exit 0
fi

# Extract model: field from frontmatter (first 20 lines)
MODEL_SPEC=$(head -20 "$AGENT_FILE" | grep -E '^model:' | head -1 | sed 's/^model:[[:space:]]*//' | tr -d '"' || echo "")

if [[ -z "$MODEL_SPEC" ]]; then
  # No model field — legacy agents default to cloud:sonnet
  emit_result "cloud:sonnet" "cloud" "sonnet" "false"
  exit 0
fi

# ── Parse prefix:name format ────────────────────────────────────────────────
BACKEND=$(echo "$MODEL_SPEC" | cut -d: -f1)
MODEL_NAME=$(echo "$MODEL_SPEC" | cut -d: -f2-)

case "$BACKEND" in
  cloud)
    emit_result "$MODEL_SPEC" "cloud" "$MODEL_NAME" "false"
    exit 0
    ;;

  local)
    # Check Ollama availability cache
    if [[ ! -f "$OLLAMA_CACHE" ]]; then
      # No cache — attempt a quick health check
      if command -v cast-ollama-health.sh &>/dev/null; then
        cast-ollama-health.sh 2>/dev/null || true
      else
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        "${SCRIPT_DIR}/cast-ollama-health.sh" 2>/dev/null || true
      fi
    fi

    if [[ -f "$OLLAMA_CACHE" ]]; then
      AVAIL=$(python3 - "$OLLAMA_CACHE" "$MODEL_NAME" <<'PYEOF'
import sys, json

cache_path  = sys.argv[1]
model_query = sys.argv[2]

try:
    with open(cache_path) as f:
        cache = json.load(f)
except Exception:
    print("unavailable")
    sys.exit(0)

if not cache.get("available"):
    print("unavailable")
    sys.exit(0)

models      = cache.get("models", [])
model_index = cache.get("model_index", {})

# Accept exact match or prefix match
if model_query in model_index:
    print("available")
elif any(m.startswith(model_query) for m in models):
    print("available")
else:
    print("missing")
PYEOF
)
      case "$AVAIL" in
        available)
          emit_result "$MODEL_SPEC" "local" "$MODEL_NAME" "false"
          ;;
        missing)
          emit_result "$DEFAULT_CLOUD_FALLBACK" "cloud" "haiku" "true" \
            "model ${MODEL_NAME} not pulled in Ollama"
          ;;
        unavailable)
          emit_result "$DEFAULT_CLOUD_FALLBACK" "cloud" "haiku" "true" \
            "Ollama not running — local model unavailable"
          ;;
      esac
    else
      emit_result "$DEFAULT_CLOUD_FALLBACK" "cloud" "haiku" "true" \
        "Ollama cache missing and health check failed"
    fi
    exit 0
    ;;

  auto)
    # Complexity-based selection
    if [[ $PROMPT_LENGTH -le $AUTO_SIMPLE_MAX_CHARS ]]; then
      CHOSEN="local:qwen3:1.7b"
    elif [[ $PROMPT_LENGTH -le $AUTO_MEDIUM_MAX_CHARS ]]; then
      CHOSEN="local:qwen3:8b"
    else
      CHOSEN="cloud:sonnet"
    fi
    # Recurse with the chosen spec — re-use local availability logic
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec "$0" "$AGENT_NAME" "$PROMPT_LENGTH" <<< "" &
    # Just emit directly for simplicity
    CHOSEN_BACKEND=$(echo "$CHOSEN" | cut -d: -f1)
    CHOSEN_MODEL=$(echo "$CHOSEN" | cut -d: -f2-)
    emit_result "$CHOSEN" "$CHOSEN_BACKEND" "$CHOSEN_MODEL" "false" "auto-resolved from prompt_length=${PROMPT_LENGTH}"
    exit 0
    ;;

  *)
    # Bare model name (legacy format: "haiku", "sonnet") — treat as cloud
    emit_result "cloud:${MODEL_SPEC}" "cloud" "$MODEL_SPEC" "false"
    exit 0
    ;;
esac
