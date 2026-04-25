#!/usr/bin/env bash
#
# cast-batch-status.sh — Poll a batch job status from Anthropic Batches API.
#
# Usage:
#   cast-batch-status.sh <batch-id>
#
# Env:
#   ANTHROPIC_API_KEY (required)
#
# Output format (stdout):
#   Tab-separated: status\tsucceeded\terrored\tcanceled\texpired
#   If status is 'ended', append result_file_url on next line
#
# Exit codes:
#   0 — success; status printed to stdout
#   1 — error; error message printed to stderr
#
# Example:
#   cast-batch-status.sh msgbatch_1234567890abcdef
#   # Output: in_progress   0   0   0   0
#

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

BATCH_ID="${1:?batch ID required}"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ANTHROPIC_API_KEY environment variable not set" >&2
  exit 1
fi

# Fetch batch status
RESPONSE=$(curl -sf "https://api.anthropic.com/v1/messages/batches/${BATCH_ID}" \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  2>&1) || {
  echo "ERROR: Batch API request failed: $RESPONSE" >&2
  exit 1
}

# Parse response
python3 -W ignore::DeprecationWarning <<PYEOF
import sys
import json

try:
  response = json.loads("""$RESPONSE""")
except json.JSONDecodeError:
  print("ERROR: Invalid JSON response", file=sys.stderr)
  sys.exit(1)

# Check for error response
if 'error' in response:
  print(f"ERROR: {response['error'].get('message', 'Unknown error')}", file=sys.stderr)
  sys.exit(1)

status = response.get('processing_status', 'unknown')
if status == 'unknown':
  print("ERROR: No processing_status in response", file=sys.stderr)
  sys.exit(1)

counts = response.get('request_counts', {})
succeeded = counts.get('succeeded', 0)
errored = counts.get('errored', 0)
canceled = counts.get('canceled', 0)
expired = counts.get('expired', 0)

# Print tab-separated counts
print(f"{status}\t{succeeded}\t{errored}\t{canceled}\t{expired}")

# If batch ended, fetch the result file URL
if status == 'ended':
  results_url = response.get('results_url', '')
  if results_url:
    print(results_url)
PYEOF
