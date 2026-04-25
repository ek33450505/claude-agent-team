#!/usr/bin/env bash
# cast-managed-agent.sh — dispatch a task via Anthropic Managed Agents
# Usage:
#   cast-managed-agent.sh <agent-name> <prompt> [--local-fallback]
# Env:
#   ANTHROPIC_API_KEY   required
# Beta header: managed-agents-2026-04-01
set -euo pipefail
# Disable xtrace globally — this script handles ANTHROPIC_API_KEY and must never echo it
set +x

# --- Subprocess bypass ---
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# --- Constants ---
BETA_HEADER="managed-agents-2026-04-01"
API_BASE="${ANTHROPIC_API_BASE:-https://api.anthropic.com}"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/managed-agent-invocations.log"

# --- Parse args ---
AGENT_NAME=""
PROMPT=""
LOCAL_FALLBACK=0

for arg in "$@"; do
  case "$arg" in
    --local-fallback)
      LOCAL_FALLBACK=1
      ;;
    *)
      if [[ -z "$AGENT_NAME" ]]; then
        AGENT_NAME="$arg"
      elif [[ -z "$PROMPT" ]]; then
        PROMPT="$arg"
      fi
      ;;
  esac
done

if [[ -z "$AGENT_NAME" || -z "$PROMPT" ]]; then
  echo "Usage: cast-managed-agent.sh <agent-name> <prompt> [--local-fallback]" >&2
  exit 2
fi

# --- Verify API key ---
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY not set" >&2
  exit 2
fi

# --- Logging setup ---
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
_log() {
  local status="$1"
  local msg="${2:-}"
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') agent=${AGENT_NAME} prompt_len=${#PROMPT} status=${status}${msg:+ msg=${msg}}" >> "$LOG_FILE"
}

_log "invoked"

# --- Build request body via python3 (safe JSON, no string concat) ---
REQUEST_BODY="$(CAST_MA_PROMPT="$PROMPT" CAST_MA_AGENT="$AGENT_NAME" python3 -c '
import json, os
name = os.environ["CAST_MA_AGENT"]
prompt = os.environ["CAST_MA_PROMPT"]
body = {
    "name": name,
    "model": os.environ.get("CAST_MANAGED_AGENT_MODEL", "claude-haiku-4-5"),
    "system": prompt,
    "tools": [{"type": "agent_toolset_20260401"}]
}
print(json.dumps(body))
')"

# --- API call ---
HTTP_RESPONSE=""
CURL_EXIT=0

HTTP_RESPONSE="$(echo "$REQUEST_BODY" | curl \
  --silent \
  --show-error \
  --fail-with-body \
  --max-redirs 3 \
  --write-out "\n__HTTP_STATUS__%{http_code}" \
  -X POST "${API_BASE}/v1/agents" \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-beta: ${BETA_HEADER}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  --data-binary @- 2>&1)" || CURL_EXIT=$?

# --- Extract HTTP status and body ---
HTTP_STATUS=""
RESPONSE_BODY=""
if [[ "$HTTP_RESPONSE" =~ __HTTP_STATUS__([0-9]+)$ ]]; then
  HTTP_STATUS="${BASH_REMATCH[1]}"
  RESPONSE_BODY="${HTTP_RESPONSE%__HTTP_STATUS__*}"
else
  RESPONSE_BODY="$HTTP_RESPONSE"
fi

# --- Handle errors ---
if [[ "$CURL_EXIT" -ne 0 ]]; then
  # Auth errors: always fail-closed regardless of --local-fallback
  if [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]]; then
    _log "auth_error" "http=${HTTP_STATUS}"
    echo "ERROR: authentication failure (HTTP ${HTTP_STATUS})" >&2
    exit 1
  fi

  TRUNCATED_BODY="${RESPONSE_BODY:0:200}"
  _log "error" "http=${HTTP_STATUS}"

  if [[ "$LOCAL_FALLBACK" -eq 1 ]]; then
    echo "WARN: Managed Agents call failed (HTTP ${HTTP_STATUS}), falling back to local dispatch" >&2
    exit 0
  else
    echo "ERROR: Managed Agents API call failed (HTTP ${HTTP_STATUS}): ${TRUNCATED_BODY}" >&2
    exit 1
  fi
fi

_log "success" "http=${HTTP_STATUS}"

# --- Emit response to stdout ---
echo "$RESPONSE_BODY"
