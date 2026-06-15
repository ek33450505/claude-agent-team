#!/usr/bin/env bash
#
# cast-batch-dispatch.sh — Submit a prompt to Anthropic Batches API for async processing.
#
# Usage:
#   cast-batch-dispatch.sh <agent-name> <prompt-file> [--model <model-id>]
#
# Env:
#   ANTHROPIC_API_KEY (required)
#   CAST_DB_PATH (optional, defaults to ~/.claude/cast.db)
#
# Exit codes:
#   0 — success; batch_id printed to stdout
#   1 — error; error message printed to stderr
#
# Example:
#   cast-batch-dispatch.sh commit "/tmp/prompt.txt" --model claude-haiku-4-5
#   # Output: msgbatch_1234567890abcdef
#

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# Defaults
MODEL="claude-haiku-4-5"

# Parse args
AGENT="${1:?agent name required}"
PROMPT_FILE="${2:?prompt file path required}"

# Handle optional --model flag
if [ $# -ge 4 ] && [ "$3" = "--model" ]; then
  MODEL="$4"
fi

# Validate AGENT name — custom_id constraint is [a-zA-Z0-9_-], <=64 chars.
# Fail fast here rather than letting the API reject.
if ! [[ "$AGENT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: agent name must match [a-zA-Z0-9_-]+: '$AGENT'" >&2
  exit 1
fi

# Validate files and env
if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ANTHROPIC_API_KEY environment variable not set" >&2
  exit 1
fi

# Read prompt
PROMPT="$(cat "$PROMPT_FILE")"

# Generate custom_id: cast-<agent>-<timestamp>
# Constraints: 1–64 chars, only [a-zA-Z0-9_-]
CUSTOM_ID="cast-${AGENT}-$(date +%s)"
if [ ${#CUSTOM_ID} -gt 64 ]; then
  CUSTOM_ID="${CUSTOM_ID:0:64}"
fi

# Build request payload
PAYLOAD=$(cat <<EOF
{
  "requests": [
    {
      "custom_id": "$CUSTOM_ID",
      "params": {
        "model": "$MODEL",
        "max_tokens": 4096,
        "messages": [
          {
            "role": "user",
            "content": $(printf '%s\n' "$PROMPT" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
          }
        ]
      }
    }
  ]
}
EOF
)

# Submit batch
RESPONSE=$(curl -sf -X POST "https://api.anthropic.com/v1/messages/batches" \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$PAYLOAD" 2>&1) || {
  echo "ERROR: Batch API request failed: $RESPONSE" >&2
  exit 1
}

# Extract batch_id
BATCH_ID=$(echo "$RESPONSE" | python3 -c 'import sys, json; d = json.load(sys.stdin); print(d.get("id", ""))' 2>/dev/null || echo "")

if [ -z "$BATCH_ID" ]; then
  echo "ERROR: No batch ID in response: $RESPONSE" >&2
  exit 1
fi

# Success: print batch_id to stdout
echo "$BATCH_ID"
