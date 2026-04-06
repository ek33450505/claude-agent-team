#!/bin/bash
# cast-ollama.sh — Ollama local model fallback for CAST offline tasks
#
# When ANTHROPIC_API_KEY is absent or airgap mode is active, provides
# a fallback to Ollama's local API for lightweight tasks like routing
# classification and memory summarization.
#
# Usage:
#   cast-ollama.sh status                Check Ollama availability
#   cast-ollama.sh query "<prompt>"      Send prompt to local model
#   cast-ollama.sh pull [model]          Pull a model via Ollama
#   cast-ollama.sh classify "<prompt>"   Classify prompt for agent routing

set -euo pipefail

SUBCMD="${1:-}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
CAST_OFFLINE_MODEL="${CAST_OFFLINE_MODEL:-phi3:mini}"
CONNECT_TIMEOUT=5
RESPONSE_TIMEOUT=30

usage() {
  cat <<USAGE
Usage: cast-ollama.sh <command> [args]

Commands:
  status                Check if Ollama is running and list models
  query "<prompt>"      Send a prompt to local model, stream response
  pull [model]          Pull a model (default: phi3:mini)
  classify "<prompt>"   Agent routing classification (JSON output)

Environment:
  CAST_OFFLINE_MODEL   Model name (default: phi3:mini)
  OLLAMA_HOST          API host (default: http://localhost:11434)
USAGE
  exit "${1:-0}"
}

# Check if Ollama is reachable
check_ollama() {
  if curl -s --connect-timeout "$CONNECT_TIMEOUT" "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

case "$SUBCMD" in
  status)
    echo "CAST Ollama Status:"
    echo "==================="

    # Check if Ollama CLI is installed
    if command -v ollama >/dev/null 2>&1; then
      OLLAMA_VERSION=$(ollama --version 2>/dev/null || echo "unknown")
      echo "  Ollama CLI: installed ($OLLAMA_VERSION)"
    else
      echo "  Ollama CLI: not installed — brew install ollama"
      echo "  Ollama API: skipped (CLI not installed)"
      exit 1
    fi

    # Check if Ollama server is running
    if check_ollama; then
      echo "  Ollama API: running at $OLLAMA_HOST"

      # List available models
      MODELS=$(curl -s --connect-timeout "$CONNECT_TIMEOUT" "${OLLAMA_HOST}/api/tags" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('models', [])
    if models:
        for m in models:
            name = m.get('name', 'unknown')
            size_gb = m.get('size', 0) / (1024**3)
            print(f'    - {name} ({size_gb:.1f} GB)')
    else:
        print('    (no models pulled)')
except Exception:
    print('    (could not parse model list)')
" 2>/dev/null)
      echo "  Models:"
      echo "$MODELS"

      # Check if configured model is available
      HAS_MODEL=$(curl -s --connect-timeout "$CONNECT_TIMEOUT" "${OLLAMA_HOST}/api/tags" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    names = [m.get('name','') for m in data.get('models',[])]
    model = '$CAST_OFFLINE_MODEL'
    print('yes' if model in names or any(n.startswith(model.split(':')[0]) for n in names) else 'no')
except Exception:
    print('no')
" 2>/dev/null)
      if [[ "$HAS_MODEL" == "yes" ]]; then
        echo "  Default model ($CAST_OFFLINE_MODEL): available"
      else
        echo "  Default model ($CAST_OFFLINE_MODEL): not pulled (run: cast-ollama.sh pull)"
      fi
    else
      echo "  Ollama API: not running (start with: ollama serve)"
      exit 1
    fi
    ;;

  query)
    PROMPT="${2:-}"
    if [[ -z "$PROMPT" ]]; then
      echo "Error: 'query' requires a prompt argument" >&2
      echo "Usage: cast-ollama.sh query \"<prompt>\"" >&2
      exit 1
    fi

    if ! check_ollama; then
      echo "Error: Ollama is not running at $OLLAMA_HOST" >&2
      echo "Start with: ollama serve" >&2
      exit 1
    fi

    # Send prompt and stream response
    curl -s --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$RESPONSE_TIMEOUT" \
      "${OLLAMA_HOST}/api/generate" \
      -d "$(python3 -c "import json; print(json.dumps({'model': '$CAST_OFFLINE_MODEL', 'prompt': '''$PROMPT''', 'stream': False}))")" \
      2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('response', ''))
except Exception as e:
    print(f'Error parsing response: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      echo "Error: Request to Ollama failed" >&2
      exit 1
    fi
    ;;

  pull)
    MODEL="${2:-$CAST_OFFLINE_MODEL}"

    if ! command -v ollama >/dev/null 2>&1; then
      echo "Error: Ollama is not installed" >&2
      echo "Install with: brew install ollama" >&2
      exit 1
    fi

    if ! check_ollama; then
      echo "Error: Ollama is not running at $OLLAMA_HOST" >&2
      echo "Start with: ollama serve" >&2
      exit 1
    fi

    echo "Pulling model: $MODEL"
    curl -s --connect-timeout "$CONNECT_TIMEOUT" \
      "${OLLAMA_HOST}/api/pull" \
      -d "{\"name\": \"$MODEL\"}" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        data = json.loads(line)
        status = data.get('status', '')
        if status:
            print(f'  {status}', flush=True)
    except Exception:
        pass
" 2>/dev/null
    echo "Pull complete: $MODEL"
    ;;

  classify)
    PROMPT="${2:-}"
    if [[ -z "$PROMPT" ]]; then
      echo "Error: 'classify' requires a prompt argument" >&2
      echo "Usage: cast-ollama.sh classify \"<prompt>\"" >&2
      exit 1
    fi

    if ! check_ollama; then
      echo "Error: Ollama is not running at $OLLAMA_HOST" >&2
      echo "Start with: ollama serve" >&2
      exit 1
    fi

    # Classification prompt with structured JSON output
    CLASSIFY_PROMPT="You are a task classifier for a multi-agent system. Given the user prompt below, classify which agent should handle it. Respond with ONLY a JSON object.

Available agents: code-writer, debugger, test-writer, security, researcher, planner, bash-specialist, devops, docs, commit, push

User prompt: ${PROMPT}

Respond with JSON: {\"agent\": \"<agent-name>\", \"confidence\": <0.0-1.0>}"

    RESPONSE=$(curl -s --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$RESPONSE_TIMEOUT" \
      "${OLLAMA_HOST}/api/generate" \
      -d "$(python3 -c "import json; print(json.dumps({'model': '$CAST_OFFLINE_MODEL', 'prompt': '''$CLASSIFY_PROMPT''', 'stream': False, 'format': 'json'}))")" \
      2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    response_text = data.get('response', '{}')
    parsed = json.loads(response_text)
    # Validate structure
    result = {
        'agent': parsed.get('agent', 'unknown'),
        'confidence': float(parsed.get('confidence', 0.0))
    }
    print(json.dumps(result))
except Exception:
    print(json.dumps({'agent': 'unknown', 'confidence': 0.0}))
" 2>/dev/null)

    echo "$RESPONSE"
    ;;

  --help|-h)
    usage 0
    ;;

  "")
    usage 1
    ;;

  *)
    echo "Error: Unknown command: $SUBCMD" >&2
    echo "Usage: cast-ollama.sh <status|query|pull|classify>" >&2
    exit 1
    ;;
esac
