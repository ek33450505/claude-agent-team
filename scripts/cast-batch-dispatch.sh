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

# Log to database
# Redact common secret patterns before storing the preview in cast.db.
# Patterns: sk-..., AKIA..., ghp_..., gha_..., glpat-..., bearer/api/secret tokens,
# generic 32+ char base64-ish blobs.
PROMPT_PREVIEW="$(printf '%s' "${PROMPT:0:200}" | python3 -c '
import re, sys
text = sys.stdin.read()
patterns = [
    r"sk-[A-Za-z0-9_-]{20,}",
    r"AKIA[0-9A-Z]{16}",
    r"gh[pousr]_[A-Za-z0-9]{20,}",
    r"glpat-[A-Za-z0-9_-]{20,}",
    r"(?i)(bearer|api[_-]?key|secret|password|token)[\"'\''\s:=]+[A-Za-z0-9_\-./+=]{8,}",
    r"[A-Za-z0-9+/]{32,}={0,2}",
]
for p in patterns:
    text = re.sub(p, "[REDACTED]", text)
sys.stdout.write(text)
')"
python3 -W ignore::DeprecationWarning - "$BATCH_ID" "$AGENT" "$CUSTOM_ID" "$PROMPT_PREVIEW" <<'PYEOF'
import sys
import os
import sqlite3
import datetime
from pathlib import Path

batch_id = sys.argv[1]
agent = sys.argv[2]
custom_id = sys.argv[3]
prompt_preview = sys.argv[4]

db_path = os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))
Path(db_path).parent.mkdir(parents=True, exist_ok=True)

try:
  conn = sqlite3.connect(db_path, timeout=5)

  # Create table if not exists
  conn.execute('''
    CREATE TABLE IF NOT EXISTS batch_dispatches (
      id TEXT PRIMARY KEY,
      batch_id TEXT NOT NULL,
      agent TEXT NOT NULL,
      custom_id TEXT NOT NULL,
      prompt_preview TEXT,
      submitted_at TEXT NOT NULL
    )
  ''')

  # Insert row
  submitted_at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
  row_id = f"{agent}_{batch_id}"
  conn.execute(
    'INSERT OR REPLACE INTO batch_dispatches (id, batch_id, agent, custom_id, prompt_preview, submitted_at) VALUES (?, ?, ?, ?, ?, ?)',
    (row_id, batch_id, agent, custom_id, prompt_preview, submitted_at)
  )
  conn.commit()
  conn.close()
except Exception as e:
  # Log error but don't fail dispatch
  log_path = Path.home() / '.claude' / 'logs' / 'batch-dispatch-errors.log'
  log_path.parent.mkdir(parents=True, exist_ok=True)
  with open(log_path, 'a') as f:
    f.write(f'[{datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")}] ERROR: {e}\n')
PYEOF

# Success: print batch_id to stdout
echo "$BATCH_ID"
