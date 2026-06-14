#!/bin/bash
# cast-tmux-session.sh — CAST tmux companion session
# Creates a tmux session with Claude Code in the main pane and a live
# CAST monitor in a side pane showing agent status, hook events, and tokens.
#
# Usage:
#   cast-tmux-session.sh [-h] [-- <claude-args>...]
#
# Examples:
#   cast-tmux-session.sh                    # Default: launch claude
#   cast-tmux-session.sh -- -p "hello"      # Pass args to claude
#   cast-tmux-session.sh -h                 # Show help

set -euo pipefail

SESSION_NAME="cast"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
EVENTS_DIR="${HOME}/.claude/cast/events"
STATUS_DIR="${HOME}/.claude/agent-status"
CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"
REFRESH_INTERVAL=10
STREAM_MODE=0

# -----------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------
usage() {
  cat <<EOF
cast-tmux-session.sh — CAST tmux companion

Usage:
  cast-tmux-session.sh [-h] [--stream] [-- <claude-args>...]

Options:
  -h, --help    Show this help message
  --stream      Enable stream-JSON observability pipeline (uses cast-stream-wrapper.sh)

The session creates two panes:
  Left (70%)  : Claude Code session
  Right (30%) : Live CAST monitor (refreshes every ${REFRESH_INTERVAL}s)

With --stream:
  The main pane runs claude through cast-stream-wrapper.sh for stream-JSON
  observability. All tool events are captured to cast.db stream_events table.
  The monitor pane shows stream_events count for the current session.

Status bar shows CAST version and session name.

Examples:
  cast-tmux-session.sh
  cast-tmux-session.sh --stream
  cast-tmux-session.sh -- --resume
  cast-tmux-session.sh -- -p "run tests"
  cast-tmux-session.sh --stream -- -p "run tests"
EOF
  exit 0
}

# -----------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------
CLAUDE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --stream)  STREAM_MODE=1; shift ;;
    --)        shift; CLAUDE_ARGS=("$@"); break ;;
    *)         CLAUDE_ARGS+=("$1"); shift ;;
  esac
done

# -----------------------------------------------------------------------
# Check dependencies
# -----------------------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then
  echo "Error: tmux is required. Install with: brew install tmux" >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude CLI not found in PATH" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Monitor script (runs in the right pane)
# -----------------------------------------------------------------------
MONITOR_SCRIPT=$(cat <<'MONITOR'
#!/bin/bash
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
EVENTS_DIR="${HOME}/.claude/cast/events"
STATUS_DIR="${HOME}/.claude/agent-status"
STREAM_SESSION_ID="${CLAUDE_SESSION_ID:-}"

render() {
  clear
  local NOW
  NOW=$(date +"%Y-%m-%d %H:%M:%S")
  local WIDTH
  WIDTH=$(tput cols 2>/dev/null || echo 40)
  local SEP
  SEP=$(printf '%*s' "$WIDTH" '' | tr ' ' '─')

  echo "  CAST Monitor  │  ${NOW}"
  echo "$SEP"

  # --- Active Agents ---
  echo "  ACTIVE AGENTS"
  echo "$SEP"
  if [ -d "$STATUS_DIR" ]; then
    local count=0
    for f in "$STATUS_DIR"/*.json; do
      [ -f "$f" ] || continue
      local agent status ts
      agent=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('agent','?'))" 2>/dev/null || echo "?")
      status=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('status','?'))" 2>/dev/null || echo "?")
      ts=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('timestamp','?')[:19])" 2>/dev/null || echo "?")
      printf "  %-18s %-20s %s\n" "$agent" "$status" "$ts"
      count=$((count + 1))
      [ "$count" -ge 8 ] && break
    done
    [ "$count" -eq 0 ] && echo "  (none)"
  else
    echo "  (no status dir)"
  fi
  echo ""

  # --- Recent Hook Events ---
  echo "  RECENT HOOK EVENTS"
  echo "$SEP"
  if [ -f "$DB_PATH" ]; then
    python3 -c "
import sqlite3, os
db = os.environ.get('DB_PATH', os.path.expanduser('~/.claude/cast.db'))
try:
    con = sqlite3.connect(db, timeout=2)
    cur = con.cursor()
    cur.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name='hook_health'\")
    if cur.fetchone():
        cur.execute('SELECT hook_name, status, timestamp FROM hook_health ORDER BY timestamp DESC LIMIT 5')
        rows = cur.fetchall()
        for r in rows:
            print(f'  {r[0]:<24} {r[1]:<8} {(r[2] or \"\")[:19]}')
        if not rows:
            print('  (no events)')
    else:
        print('  (hook_health table not found)')
    con.close()
except Exception as e:
    print(f'  (db error: {e})')
" 2>/dev/null || echo "  (query failed)"
  else
    echo "  (no cast.db)"
  fi
  echo ""

  # --- Session Info ---
  echo "  SESSION INFO"
  echo "$SEP"
  if [ -f "$DB_PATH" ]; then
    python3 -c "
import sqlite3, os
db = os.environ.get('DB_PATH', os.path.expanduser('~/.claude/cast.db'))
try:
    con = sqlite3.connect(db, timeout=2)
    cur = con.cursor()
    cur.execute('SELECT id, project, started_at FROM sessions ORDER BY started_at DESC LIMIT 1')
    row = cur.fetchone()
    if row:
        print(f'  Session:  {(row[0] or \"?\")[:16]}...')
        print(f'  Project:  {row[1] or \"?\"}')
        print(f'  Started:  {(row[2] or \"?\")[:19]}')
    else:
        print('  (no sessions)')
    con.close()
except Exception as e:
    print(f'  (db error: {e})')
" 2>/dev/null || echo "  (query failed)"
  fi
  echo ""

  # --- Stream Events (shown when stream mode active) ---
  if [ -n "$STREAM_SESSION_ID" ] && [ -f "$DB_PATH" ]; then
    echo "  STREAM EVENTS"
    echo "$SEP"
    python3 -c "
import sqlite3, os
db = os.environ.get('DB_PATH', os.path.expanduser('~/.claude/cast.db'))
sid = os.environ.get('CLAUDE_SESSION_ID', '')
try:
    con = sqlite3.connect(db, timeout=2)
    cur = con.cursor()
    cur.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name='stream_events'\")
    if cur.fetchone():
        cur.execute('SELECT COUNT(*) FROM stream_events WHERE session_id = ?', (sid,))
        count = cur.fetchone()[0]
        print(f'  Stream events this session: {count}')
        cur.execute('SELECT event_type, tool_name, timestamp FROM stream_events WHERE session_id = ? ORDER BY timestamp DESC LIMIT 3', (sid,))
        for r in cur.fetchall():
            print(f'  {r[0]:<18} {(r[1] or \"\"):<20} {(r[2] or \"\")[:19]}')
    con.close()
except Exception as e:
    print(f'  (stream query error: {e})')
" 2>/dev/null || true
    echo ""
  fi

  # --- Today's Activity ---
  echo "  TODAY'S ACTIVITY"
  echo "$SEP"
  local TODAY
  TODAY=$(date +%Y%m%d)
  if [ -d "$EVENTS_DIR" ]; then
    local event_count
    event_count=$(ls "$EVENTS_DIR" 2>/dev/null | grep -c "^${TODAY}T" || echo 0)
    echo "  Events today: $event_count"
  fi
  if [ -f "$DB_PATH" ]; then
    python3 -c "
import sqlite3, os
from datetime import date
db = os.environ.get('DB_PATH', os.path.expanduser('~/.claude/cast.db'))
today = date.today().isoformat()
try:
    con = sqlite3.connect(db, timeout=2)
    cur = con.cursor()
    cur.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name='agent_runs'\")
    if cur.fetchone():
        cur.execute(f\"SELECT COUNT(*) FROM agent_runs WHERE started_at >= '{today}'\")
        print(f'  Agent runs today: {cur.fetchone()[0]}')
    con.close()
except Exception:
    pass
" 2>/dev/null || true
  fi
}

while true; do
  render
  sleep "${CAST_MONITOR_INTERVAL:-10}"
done
MONITOR
)

# -----------------------------------------------------------------------
# Create tmux session
# -----------------------------------------------------------------------

# Kill existing session if present
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# Determine main pane command (stream mode or normal)
if [ "$STREAM_MODE" -eq 1 ]; then
  CLAUDE_SESSION_ID="stream-$(date +%Y%m%d%H%M%S)"
  export CLAUDE_SESSION_ID
  MAIN_CMD="\"${CAST_SCRIPTS_DIR}/cast-stream-wrapper.sh\" ${CLAUDE_ARGS[*]:-}; exec bash"
else
  MAIN_CMD="claude ${CLAUDE_ARGS[*]:-}; exec bash"
fi

# Create session with claude in the main pane
tmux new-session -d -s "$SESSION_NAME" -x "$(tput cols)" -y "$(tput lines)" \
  "$MAIN_CMD"

# Split right pane for monitor (30% width)
tmux split-window -h -t "$SESSION_NAME" -p 30 \
  "bash -c '${MONITOR_SCRIPT}'"

# Set status bar
CAST_VERSION=$(cast --version 2>/dev/null | head -1 || echo "CAST")
tmux set-option -t "$SESSION_NAME" status-left " ${CAST_VERSION} "
tmux set-option -t "$SESSION_NAME" status-right " #S "
tmux set-option -t "$SESSION_NAME" status-style "bg=colour236,fg=colour248"

# Focus the main (claude) pane
tmux select-pane -t "$SESSION_NAME":0.0

# Attach
tmux attach-session -t "$SESSION_NAME"
