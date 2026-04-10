#!/bin/bash
# cast-channel-start.sh — Start the CAST channel event bus as a background daemon.
#
# Usage:
#   cast-channel-start.sh [--port 9200] [--stop] [--status]
#
# Environment:
#   CAST_CHANNEL_PORT  Override port (default: 9200)
#   CAST_SCRIPTS_DIR   Override scripts directory (default: ~/.claude/scripts)

set -euo pipefail

CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"
CAST_CHANNEL_PORT="${CAST_CHANNEL_PORT:-9200}"
PID_FILE="${HOME}/.claude/cast-channel-server.pid"
LOG_FILE="${HOME}/.claude/logs/cast-channel-server.log"
PORT="$CAST_CHANNEL_PORT"

# Parse args
ACTION="start"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --stop)   ACTION="stop" ;;
    --status) ACTION="status" ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"

case "$ACTION" in
  stop)
    if [ -f "$PID_FILE" ]; then
      PID=$(cat "$PID_FILE")
      if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        rm -f "$PID_FILE"
        echo "cast-channel-server stopped (PID $PID)"
      else
        echo "cast-channel-server not running (stale PID file)"
        rm -f "$PID_FILE"
      fi
    else
      echo "cast-channel-server not running"
    fi
    ;;

  status)
    if [ -f "$PID_FILE" ]; then
      PID=$(cat "$PID_FILE")
      if kill -0 "$PID" 2>/dev/null; then
        echo "cast-channel-server running on port $PORT (PID $PID)"
        curl -sf "http://127.0.0.1:${PORT}/health" 2>/dev/null && echo "" || echo "(health check failed)"
      else
        echo "cast-channel-server not running (stale PID file)"
      fi
    else
      echo "cast-channel-server not running"
    fi
    ;;

  start)
    # Stop existing instance
    if [ -f "$PID_FILE" ]; then
      OLD_PID=$(cat "$PID_FILE")
      kill "$OLD_PID" 2>/dev/null || true
      rm -f "$PID_FILE"
    fi

    # Start server in background
    CAST_CHANNEL_PORT="$PORT" python3 "${CAST_SCRIPTS_DIR}/cast-channel-server.py" \
      --port "$PORT" >> "$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$PID_FILE"

    # Health check with retry
    sleep 0.5
    for i in 1 2 3; do
      if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        echo "cast-channel-server started on port $PORT (PID $SERVER_PID)"
        exit 0
      fi
      sleep 0.5
    done

    echo "Warning: cast-channel-server may not have started. Check $LOG_FILE" >&2
    ;;
esac
