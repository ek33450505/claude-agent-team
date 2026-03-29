#!/bin/bash
# cast-fswatcher.sh — CAST File System Watcher
#
# Purpose:
#   Watch configured paths for file changes and enqueue CAST agent tasks
#   automatically when matching patterns are modified.
#
# Usage:
#   cast-fswatcher.sh [--daemon] [--config path] [--stop]
#
#   --daemon       Fork to background, write PID to ~/.claude/cast/fswatcher.pid
#   --config path  Path to watch rules JSON (default: ~/.claude/config/fs-watchers.json)
#   --stop         Stop the running background watcher

set -euo pipefail

# Guard: do not run recursively inside CAST subprocess chains
if [ "${CAST_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

CAST_DIR="${HOME}/.claude/cast"
DEFAULT_CONFIG="${HOME}/.claude/config/fs-watchers.json"
PIDFILE="${CAST_DIR}/fswatcher.pid"
COOLDOWNS_FILE="${CAST_DIR}/fswatcher-cooldowns.json"
CAST_BIN="${HOME}/.local/bin/cast"

# --- Argument parsing ---
DAEMON_MODE=0
STOP_MODE=0
CONFIG_PATH="$DEFAULT_CONFIG"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon) DAEMON_MODE=1; shift ;;
    --stop)   STOP_MODE=1; shift ;;
    --config)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --config requires a path argument" >&2
        exit 1
      fi
      CONFIG_PATH="$2"; shift 2 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: cast-fswatcher.sh [--daemon] [--config path] [--stop]" >&2
      exit 1 ;;
  esac
done

# --- Stop mode ---
if [[ "$STOP_MODE" -eq 1 ]]; then
  if [[ ! -f "$PIDFILE" ]]; then
    echo "WARN: No pidfile found at $PIDFILE — watcher may not be running" >&2
    exit 0
  fi
  pid="$(cat "$PIDFILE")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    rm -f "$PIDFILE"
    echo "Stopped fswatcher (PID $pid)"
  else
    echo "WARN: PID $pid is not running — cleaning up pidfile" >&2
    rm -f "$PIDFILE"
  fi
  exit 0
fi

# --- Validate config ---
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: $CONFIG_PATH" >&2
  echo "Copy config/fs-watchers.json.template to $CONFIG_PATH to get started." >&2
  exit 1
fi

# --- Check for watcher tool ---
UNAME="$(uname -s 2>/dev/null || echo unknown)"
WATCHER_CMD=""

if [[ "$UNAME" == "Darwin" ]]; then
  if command -v fswatch >/dev/null 2>&1; then
    WATCHER_CMD="fswatch"
  else
    echo "ERROR: fswatch not found. Install with: brew install fswatch" >&2
    exit 1
  fi
else
  if command -v inotifywait >/dev/null 2>&1; then
    WATCHER_CMD="inotifywait"
  else
    echo "ERROR: inotifywait not found. Install with: apt-get install inotify-tools" >&2
    exit 1
  fi
fi

# --- Daemon fork ---
if [[ "$DAEMON_MODE" -eq 1 ]]; then
  mkdir -p "$CAST_DIR"
  # Re-exec without --daemon, backgrounded
  nohup "$0" --config "$CONFIG_PATH" >"${CAST_DIR}/fswatcher.log" 2>&1 &
  bg_pid=$!
  echo "$bg_pid" > "$PIDFILE"
  echo "fswatcher started in background (PID $bg_pid)"
  exit 0
fi

# --- Write own PID if running in foreground ---
mkdir -p "$CAST_DIR"
echo "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# --- Parse config ---
# Pass CONFIG_PATH as argv to avoid injection (path may contain spaces)
watch_root="$(python3 - "$CONFIG_PATH" <<'PYEOF' 2>/dev/null || echo ".")
import json, sys
cfg = json.load(open(sys.argv[1]))
print(cfg.get('watch_root', '.'))
PYEOF"

# Expand ~ in watch_root
watch_root="${watch_root/#\~/$HOME}"

# Write rules JSON to a temp file to avoid embedding complex JSON in shell variables
RULES_TMPFILE="$(mktemp "${TMPDIR:-/tmp}/cast-fswatcher-rules.XXXXXX.json")"
trap 'rm -f "$RULES_TMPFILE"; rm -f "$PIDFILE"' EXIT
python3 - "$CONFIG_PATH" "$RULES_TMPFILE" <<'PYEOF' 2>/dev/null || echo "[]" > "$RULES_TMPFILE"
import json, sys
cfg = json.load(open(sys.argv[1]))
open(sys.argv[2], 'w').write(json.dumps(cfg.get('rules', [])))
PYEOF

# --- Cooldown helpers ---
check_and_set_cooldown() {
  local key="$1"
  local cooldown_secs="$2"
  # Pass all values as argv to avoid shell injection into Python source
  python3 - "$key" "$cooldown_secs" "$COOLDOWNS_FILE" <<'PYEOF' 2>/dev/null || echo "ok"
import json, sys, time
from pathlib import Path
key, cooldown_secs, cooldowns_path = sys.argv[1], float(sys.argv[2]), sys.argv[3]
f = Path(cooldowns_path)
try:
  data = json.loads(f.read_text()) if f.exists() else {}
except Exception:
  data = {}
if not isinstance(data, dict):
  data = {}
last = data.get(key, 0)
now = time.time()
if now - last < cooldown_secs:
  print('skip')
else:
  data[key] = now
  f.write_text(json.dumps(data, indent=2))
  print('ok')
PYEOF
}

# --- Event handler ---
handle_file_event() {
  local changed_file="$1"

  # Pass rules via temp file path (argv) to avoid embedding JSON in shell variables
  python3 - "$changed_file" "$RULES_TMPFILE" "$CAST_DIR" <<'PYEOF'
import json, sys, re, subprocess, os
from pathlib import Path
from fnmatch import fnmatch

changed = sys.argv[1]
rules = json.loads(open(sys.argv[2]).read())
cast_dir = sys.argv[3]
cast_bin = os.path.expanduser("~/.local/bin/cast")

for rule in rules:
    pattern  = rule.get("pattern", "")
    agent    = rule.get("agent", "")
    task_tpl = rule.get("task", "")
    priority = rule.get("priority", 5)

    # Simple glob match on filename and path
    filename = Path(changed).name
    if not (fnmatch(changed, pattern) or fnmatch(filename, pattern)):
        # Try without brace expansion (basic match)
        # Strip {a,b,c} alternatives — do a best-effort check
        base_pattern = re.sub(r'\{[^}]+\}', '*', pattern)
        if not (fnmatch(changed, base_pattern) or fnmatch(filename, base_pattern)):
            continue

    task = task_tpl.replace("{file}", changed)

    print(f"MATCH: {pattern} → agent={agent} file={changed}", flush=True)

    if not os.path.exists(cast_bin):
        print(f"WARN: cast CLI not found at {cast_bin} (REQUIRES: phase-7e)", flush=True)
        continue

    # REQUIRES: phase-7e (cast CLI)
    try:
        subprocess.run(
            [cast_bin, "queue", "add",
             "--agent", agent,
             "--task", task,
             "--priority", str(priority)],
            timeout=10,
            check=False,
        )
    except Exception as e:
        print(f"WARN: Failed to enqueue task: {e}", flush=True)
PYEOF
}

# --- Start watching ---
echo "cast-fswatcher: watching $watch_root with $WATCHER_CMD"

if [[ "$WATCHER_CMD" == "fswatch" ]]; then
  fswatch -r --event Created --event Updated --event Renamed "$watch_root" | while read -r changed_file; do
    # Run cooldown + enqueue check per file
    rule_key="$(echo "$changed_file" | tr '/' '_' | tr ' ' '_')"
    cooldown_secs="$(python3 -c "
import json, sys
rules = json.load(open(sys.argv[1]))
print(min((r.get('cooldown_seconds', 30) for r in rules), default=30))
" "$RULES_TMPFILE" 2>/dev/null || echo 30)"

    result="$(check_and_set_cooldown "$rule_key" "$cooldown_secs")"
    if [[ "$result" == "skip" ]]; then
      continue
    fi
    handle_file_event "$changed_file"
  done
else
  # inotifywait (Linux)
  inotifywait -m -r -e modify,create,moved_to --format "%w%f" "$watch_root" | while read -r changed_file; do
    rule_key="$(echo "$changed_file" | tr '/' '_' | tr ' ' '_')"
    cooldown_secs="$(python3 -c "
import json, sys
rules = json.load(open(sys.argv[1]))
print(min((r.get('cooldown_seconds', 30) for r in rules), default=30))
" "$RULES_TMPFILE" 2>/dev/null || echo 30)"

    result="$(check_and_set_cooldown "$rule_key" "$cooldown_secs")"
    if [[ "$result" == "skip" ]]; then
      continue
    fi
    handle_file_event "$changed_file"
  done
fi
