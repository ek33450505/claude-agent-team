#!/bin/bash
# cast-channel-publish.sh — Thin bash wrapper for publishing events to the CAST channel server.
#
# Usage:
#   source cast-channel-publish.sh
#   cast_channel_publish '{"type":"tool_use","tool_name":"Bash"}'
#
# Or directly:
#   cast-channel-publish.sh '{"type":"tool_use","tool_name":"Bash"}'
#
# Fails silently if the channel server is not running (non-blocking).
# Safe to source from hook scripts.

CAST_CHANNEL_PORT="${CAST_CHANNEL_PORT:-9200}"

cast_channel_publish() {
  local payload="${1:-}"
  if [ -z "$payload" ]; then
    return 0
  fi
  curl -sf "http://127.0.0.1:${CAST_CHANNEL_PORT}/publish" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    --max-time 1 \
    2>/dev/null || true
}

# If called directly (not sourced), publish the first argument
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cast_channel_publish "${1:-}"
fi
