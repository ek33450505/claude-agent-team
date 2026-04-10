#!/bin/bash
# cast-litellm-start.sh — Start LiteLLM proxy for CAST Ollama contractor routing.
#
# Routes:
#   local-commit → ollama/tavernari/git-commit-message (localhost:11434)
#   local-fast   → ollama/qwen2.5-coder:7b             (localhost:11434)
#   claude-*     → Anthropic API (fallback)
#
# Usage:
#   cast-litellm-start.sh [--stop] [--status] [--port PORT]
#
# Environment:
#   CAST_LITELLM_PORT    Override port (default: 4000)
#   CAST_CONFIG_DIR      Override config dir (default: ~/.claude/config)

set -euo pipefail

CAST_CONFIG_DIR="${CAST_CONFIG_DIR:-${HOME}/.claude/config}"
CAST_LITELLM_PORT="${CAST_LITELLM_PORT:-4000}"
PID_FILE="${HOME}/.claude/cast-litellm.pid"
LOG_FILE="${HOME}/.claude/logs/cast-litellm.log"
CONFIG_FILE="${CAST_CONFIG_DIR}/cast-litellm.yaml"
PORT="$CAST_LITELLM_PORT"

ACTION="start"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop)   ACTION="stop" ;;
    --status) ACTION="status" ;;
    --port)   PORT="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG_FILE")"

# --- stop ---
if [ "$ACTION" = "stop" ]; then
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      rm -f "$PID_FILE"
      echo "cast-litellm stopped (PID $PID)"
    else
      echo "cast-litellm not running (stale PID file)"
      rm -f "$PID_FILE"
    fi
  else
    echo "cast-litellm not running"
  fi
  exit 0
fi

# --- status ---
if [ "$ACTION" = "status" ]; then
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo "cast-litellm running on port $PORT (PID $PID)"
      curl -sf "http://127.0.0.1:${PORT}/health" 2>/dev/null && echo "" || echo "(health check failed)"
    else
      echo "cast-litellm not running (stale PID file)"
    fi
  else
    echo "cast-litellm not running"
  fi
  exit 0
fi

# --- start ---

# 1. Check litellm installed
if ! pip3 show litellm >/dev/null 2>&1; then
  echo "Error: litellm is not installed." >&2
  echo "Install it with: pip3 install litellm[proxy]" >&2
  exit 1
fi

# 2. Check config file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# 3. Check Ollama running (warn only — Claude models still work without it)
if ! curl -sf --connect-timeout 2 "http://localhost:11434/api/tags" >/dev/null 2>&1; then
  echo "Warning: Ollama not running at localhost:11434. Local models unavailable." >&2
  echo "  Start Ollama: ollama serve" >&2
else
  # 4. Pull required models if not already present
  EXISTING_MODELS="$(curl -sf "http://localhost:11434/api/tags" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    names = [m.get('name', '') for m in data.get('models', [])]
    print('\n'.join(names))
except Exception:
    pass
" 2>/dev/null || true)"

  for MODEL in "tavernari/git-commit-message" "qwen2.5-coder:7b"; do
    if echo "$EXISTING_MODELS" | grep -q "^${MODEL}$"; then
      echo "Model already present: $MODEL"
    else
      echo "Pulling model: $MODEL ..."
      ollama pull "$MODEL" || echo "Warning: failed to pull $MODEL — continuing" >&2
    fi
  done
fi

# 5. Stop any existing instance
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  kill "$OLD_PID" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

# 6. Start litellm as background daemon
litellm --config "$CONFIG_FILE" --port "$PORT" >> "$LOG_FILE" 2>&1 &
LITELLM_PID=$!
echo "$LITELLM_PID" > "$PID_FILE"

# 7. Health check with retry
sleep 1
for i in 1 2 3 4 5; do
  if curl -sf --connect-timeout 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "cast-litellm started on port $PORT (PID $LITELLM_PID)"
    echo "  Config: $CONFIG_FILE"
    echo "  Log:    $LOG_FILE"
    exit 0
  fi
  sleep 1
done

echo "Warning: cast-litellm may not have started. Check $LOG_FILE" >&2
