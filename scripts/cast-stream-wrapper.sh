#!/bin/bash
# cast-stream-wrapper.sh — Wraps claude -p with the CAST stream-JSON observability pipeline.
#
# Usage:
#   cast-stream-wrapper.sh "prompt here" [additional claude flags]
#
# Streams output through cast-stream-consumer.py for DB logging, then
# prints only assistant text responses to stdout.
#
# Environment:
#   CAST_SCRIPTS_DIR   Override scripts directory (default: ~/.claude/scripts)
#   CAST_DB_PATH       Override cast.db path

set -euo pipefail

CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"

# Tag this session for the consumer
export CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID:-stream-$(date +%Y%m%d%H%M%S)}"

if [ $# -eq 0 ]; then
  echo "Usage: cast-stream-wrapper.sh \"prompt here\" [additional claude flags]" >&2
  exit 1
fi

# Run claude with stream-json output, tee through the consumer, extract assistant text
claude -p "$@" --output-format stream-json --include-hook-events \
  | tee >(python3 "${CAST_SCRIPTS_DIR}/cast-stream-consumer.py") \
  | jq -r 'select(.type == "assistant") | .content // empty' 2>/dev/null || true
