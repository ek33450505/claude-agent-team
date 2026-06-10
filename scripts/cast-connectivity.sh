#!/bin/bash
# cast-connectivity.sh — Network status detection and offline queue replay
#
# Auto-detects network status via ping to api.anthropic.com. When offline,
# provides queue functionality to store pending requests for later replay.
# Works alongside existing cast-queue-add.sh / cast-queue-processor.sh and
# cast-airgap.sh (manual air-gap toggle).
#
# Usage:
#   cast-connectivity.sh check                   Check if online (exit 0) or offline (exit 1)
#   cast-connectivity.sh queue <agent> <task>     Queue a task for offline replay
#   cast-connectivity.sh replay                   Replay queued tasks (if online)
#   cast-connectivity.sh status                   Report connectivity and queue state

set -euo pipefail

SUBCMD="${1:-}"
OFFLINE_QUEUE_DIR="${CAST_OFFLINE_QUEUE_DIR:-${HOME}/.claude/cast/offline-queue}"
PING_HOST="${CAST_PING_HOST:-api.anthropic.com}"
PING_TIMEOUT=2

usage() {
  cat <<USAGE
Usage: cast-connectivity.sh <command> [args]

Commands:
  check                   Check network status (exit 0=online, 1=offline)
  queue <agent> <task>    Queue a task JSON for offline replay
  replay                  Drain offline queue when back online
  status                  Report: online/offline, queue depth, last replay

Environment:
  CAST_OFFLINE_QUEUE_DIR   Queue directory (default: ~/.claude/cast/offline-queue)
  CAST_PING_HOST           Host to ping (default: api.anthropic.com)
USAGE
  exit "${1:-0}"
}

# Check connectivity by pinging the API host
check_connectivity() {
  if ping -c 1 -W "$PING_TIMEOUT" "$PING_HOST" >/dev/null 2>&1; then
    echo "online"
    return 0
  else
    echo "offline"
    return 1
  fi
}

case "$SUBCMD" in
  check)
    check_connectivity
    ;;

  queue)
    AGENT="${2:-}"
    TASK="${3:-}"
    if [[ -z "$AGENT" || -z "$TASK" ]]; then
      echo "Error: 'queue' requires <agent> and <task> arguments" >&2
      echo "Usage: cast-connectivity.sh queue <agent> <task-description>" >&2
      exit 1
    fi

    mkdir -p "$OFFLINE_QUEUE_DIR"

    TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
    QUEUE_FILE="${OFFLINE_QUEUE_DIR}/${TIMESTAMP}.json"

    python3 - "$AGENT" "$TASK" "$QUEUE_FILE" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

agent, task, filepath = sys.argv[1:]
entry = {
    "agent": agent,
    "task": task,
    "queued_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}
with open(filepath, 'w') as f:
    json.dump(entry, f, indent=2)
print(f"Queued task for agent '{agent}' at {filepath}")
PYEOF
    ;;

  replay)
    mkdir -p "$OFFLINE_QUEUE_DIR"

    # Check connectivity first
    if ! ping -c 1 -W "$PING_TIMEOUT" "$PING_HOST" >/dev/null 2>&1; then
      echo "Cannot replay: still offline" >&2
      exit 1
    fi

    QUEUE_FILES=$(find "$OFFLINE_QUEUE_DIR" -name "*.json" -type f 2>/dev/null | sort)
    if [[ -z "$QUEUE_FILES" ]]; then
      echo "Offline queue is empty — nothing to replay"
      exit 0
    fi

    REPLAYED=0
    FAILED=0
    CAST_QUEUE_ADD="${HOME}/.claude/scripts/cast-queue-add.sh"

    while IFS= read -r queue_file; do
      if [[ ! -f "$queue_file" ]]; then
        continue
      fi

      # Read the queued task
      AGENT=$(python3 -c "import json; d=json.load(open('$queue_file')); print(d.get('agent',''))" 2>/dev/null || echo "")
      TASK=$(python3 -c "import json; d=json.load(open('$queue_file')); print(d.get('task',''))" 2>/dev/null || echo "")

      if [[ -z "$AGENT" || -z "$TASK" ]]; then
        echo "  Skipped malformed entry: $queue_file" >&2
        FAILED=$((FAILED + 1))
        continue
      fi

      # Feed into existing queue system if available, otherwise just log
      if [[ -x "$CAST_QUEUE_ADD" ]]; then
        if bash "$CAST_QUEUE_ADD" "$AGENT" "$TASK" 2>/dev/null; then
          rm -f "$queue_file"
          REPLAYED=$((REPLAYED + 1))
        else
          echo "  Failed to replay: $queue_file" >&2
          FAILED=$((FAILED + 1))
        fi
      else
        echo "  Replayed (cast-queue-add.sh not found, logged only): agent=$AGENT task=$TASK"
        rm -f "$queue_file"
        REPLAYED=$((REPLAYED + 1))
      fi
    done <<< "$QUEUE_FILES"

    # Record last replay timestamp
    date -u +%Y-%m-%dT%H:%M:%SZ > "${OFFLINE_QUEUE_DIR}/.last-replay"

    echo ""
    echo "Replay complete: $REPLAYED replayed, $FAILED failed"
    ;;

  status)
    echo "CAST Connectivity Status:"
    echo "========================="

    # Online/offline
    if ping -c 1 -W "$PING_TIMEOUT" "$PING_HOST" >/dev/null 2>&1; then
      echo "  Network: online (${PING_HOST} reachable)"
    else
      echo "  Network: offline (${PING_HOST} unreachable)"
    fi

    # Queue depth
    mkdir -p "$OFFLINE_QUEUE_DIR"
    QUEUE_DEPTH=$(find "$OFFLINE_QUEUE_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "  Offline queue: $QUEUE_DEPTH pending item(s)"

    # Last replay
    LAST_REPLAY_FILE="${OFFLINE_QUEUE_DIR}/.last-replay"
    if [[ -f "$LAST_REPLAY_FILE" ]]; then
      LAST_REPLAY=$(cat "$LAST_REPLAY_FILE")
      echo "  Last replay: $LAST_REPLAY"
    else
      echo "  Last replay: never"
    fi

    # Airgap mode
    AIRGAP_STATE="${HOME}/.claude/cast/state/airgap.state"
    if [[ -f "$AIRGAP_STATE" ]] && [[ "$(cat "$AIRGAP_STATE")" == "1" ]]; then
      echo "  Airgap mode: ON (manual override)"
    else
      echo "  Airgap mode: OFF"
    fi
    ;;

  --help|-h)
    usage 0
    ;;

  "")
    usage 1
    ;;

  *)
    echo "Error: Unknown command: $SUBCMD" >&2
    echo "Usage: cast-connectivity.sh <check|queue|replay|status>" >&2
    exit 1
    ;;
esac
