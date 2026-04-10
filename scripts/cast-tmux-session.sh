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
REFRESH_INTERVAL=10

# -----------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------
usage() {
  cat <<EOF
cast-tmux-session.sh — CAST tmux companion

Usage:
  cast-tmux-session.sh [-h] [-- <claude-args>...]

Options:
  -h, --help    Show this help message

The session creates two panes:
  Left (70%)  : Claude Code session
  Right (30%) : Live CAST monitor (refreshes every ${REFRESH_INTERVAL}s)

Status bar shows CAST version and session name.

Examples:
  cast-tmux-session.sh
  cast-tmux-session.sh -- --resume
  cast-tmux-session.sh -- -p "run tests"
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

# Create session with claude in the main pane
tmux new-session -d -s "$SESSION_NAME" -x "$(tput cols)" -y "$(tput lines)" \
  "claude ${CLAUDE_ARGS[*]:-}; exec bash"

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
