#!/bin/bash
# cast-notify.sh — CAST Notification Center integration
#
# Purpose:
#   Send native desktop notifications for CAST events.
#   macOS uses osascript, Linux uses notify-send, both append to notify-queue.json.
#
# Usage:
#   cast-notify.sh <event_type> [message] [title]
#
# Event types:
#   blocked           — agent blocked, needs user attention
#   queue_complete    — all queued tasks finished
#   budget_alert      — spending threshold exceeded
#   briefing_ready    — morning briefing is available

set -euo pipefail

# Guards
if [ "${CAST_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

CAST_DIR="${HOME}/.claude/cast"
NOTIFY_QUEUE_FILE="${CAST_DIR}/notify-queue.json"
NOTIFICATIONS_CONFIG="${HOME}/.claude/config/notifications.json"
MAX_QUEUE_ENTRIES=50

EVENT_TYPE="${1:-}"
MESSAGE="${2:-}"
TITLE="${3:-CAST}"

if [ -z "$EVENT_TYPE" ]; then
  echo "Usage: cast-notify.sh <event_type> [message] [title]" >&2
  echo "Event types: blocked, queue_complete, budget_alert, briefing_ready" >&2
  exit 0
fi

# --- Read notifications config ---
notifications_enabled() {
  if [ ! -f "$NOTIFICATIONS_CONFIG" ]; then
    echo "true"
    return
  fi
  python3 -c "
import json, sys
try:
  cfg = json.load(open('${NOTIFICATIONS_CONFIG}'))
  print('true' if cfg.get('enabled', True) else 'false')
except Exception:
  print('true')
" 2>/dev/null || echo "true"
}

event_enabled() {
  local event="$1"
  if [ ! -f "$NOTIFICATIONS_CONFIG" ]; then
    echo "true"
    return
  fi
  python3 -c "
import json
try:
  cfg = json.load(open('${NOTIFICATIONS_CONFIG}'))
  events = cfg.get('events', {})
  print('true' if events.get('${event}', True) else 'false')
except Exception:
  print('true')
" 2>/dev/null || echo "true"
}

in_quiet_hours() {
  if [ ! -f "$NOTIFICATIONS_CONFIG" ]; then
    echo "false"
    return
  fi
  python3 -c "
import json
from datetime import datetime
try:
  cfg = json.load(open('${NOTIFICATIONS_CONFIG}'))
  start = cfg.get('quiet_hours_start', 22)
  end   = cfg.get('quiet_hours_end', 8)
  now   = datetime.now().hour
  if start > end:
    quiet = now >= start or now < end
  else:
    quiet = start <= now < end
  print('true' if quiet else 'false')
except Exception:
  print('false')
" 2>/dev/null || echo "false"
}

# --- Eligibility checks ---
if [ "$(notifications_enabled)" = "false" ]; then exit 0; fi
if [ "$(event_enabled "$EVENT_TYPE")" = "false" ]; then exit 0; fi
if [ "$(in_quiet_hours)" = "true" ]; then
  # Budget alerts bypass quiet hours
  if [ "$EVENT_TYPE" != "budget_alert" ]; then exit 0; fi
fi

# --- Choose notification sound ---
case "$EVENT_TYPE" in
  blocked|budget_alert)
    SOUND="Bottle"
    ;;
  queue_complete|briefing_ready)
    SOUND="Glass"
    ;;
  *)
    SOUND="Glass"
    ;;
esac

# --- Default message if empty ---
if [ -z "$MESSAGE" ]; then
  case "$EVENT_TYPE" in
    blocked)        MESSAGE="An agent is blocked and needs attention." ;;
    queue_complete) MESSAGE="All queued tasks have completed." ;;
    budget_alert)   MESSAGE="CAST budget threshold exceeded." ;;
    briefing_ready) MESSAGE="Your morning briefing is ready." ;;
    *)              MESSAGE="$EVENT_TYPE" ;;
  esac
fi

# --- Append to notify-queue.json (used by status bar app) ---
mkdir -p "$CAST_DIR"
append_to_queue() {
  local event="$1"
  local msg="$2"
  local ttl="$3"
  # Pass values as arguments to avoid shell variable injection into Python source
  python3 - "$event" "$msg" "$ttl" "$NOTIFY_QUEUE_FILE" "$MAX_QUEUE_ENTRIES" <<'PYEOF' 2>/dev/null || true
import json, sys, time
from pathlib import Path
event, msg, ttl, queue_path, max_entries = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
queue_file = Path(queue_path)
try:
  entries = json.loads(queue_file.read_text()) if queue_file.exists() else []
except Exception:
  entries = []
if not isinstance(entries, list):
  entries = []
entries.append({
  'event': event,
  'title': ttl,
  'message': msg,
  'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
  'delivered': False
})
entries = entries[-max_entries:]
queue_file.write_text(json.dumps(entries, indent=2))
PYEOF
}

append_to_queue "$EVENT_TYPE" "$MESSAGE" "$TITLE"

# --- Platform notification ---
UNAME="$(uname -s 2>/dev/null || echo unknown)"

if [ "$UNAME" = "Darwin" ]; then
  # macOS: osascript notification — use heredoc to avoid shell injection
  osascript 2>/dev/null <<APPLESCRIPT || true
display notification "$( printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' )" with title "$( printf '%s' "$TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' )" sound name "${SOUND}"
APPLESCRIPT
else
  # Linux: notify-send if available
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$TITLE" "$MESSAGE" 2>/dev/null || true
  fi
  # notify-queue.json already written above — status bar app will display it
fi

exit 0
