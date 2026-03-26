#!/bin/bash
# cast-sync.sh — CAST cross-machine sync via rsync
#
# Purpose:
#   Sync CAST state (cast.db, memories, config) to/from a remote machine.
#   Never syncs ephemeral files (logs, pids, sockets, event streams).
#
# Usage:
#   cast-sync.sh <push|pull|status|config> [--remote user@host:~/.claude/]
#
# Commands:
#   push    — rsync local CAST state to remote (pauses daemon during sync)
#   pull    — dry-run, show diff, confirm before applying
#   status  — show rsync dry-run diff without making changes
#   config  — show or set the default remote in ~/.claude/config/sync.json

set -euo pipefail

# Guard: do not run recursively inside CAST subprocess chains
if [ "${CAST_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

CAST_DIR="${HOME}/.claude/cast"
CLAUDE_DIR="${HOME}/.claude"
SYNC_CONFIG="${HOME}/.claude/config/sync.json"
CASTD_STATE_FILE="${CAST_DIR}/castd.state"
CASTD_PID_FILE="${CAST_DIR}/castd.pid"

# Color helpers (only when writing to a tty)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  RESET='\033[0m'
else
  GREEN='' YELLOW='' RED='' RESET=''
fi

info()  { echo -e "${GREEN}[sync]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET} $*" >&2; }
error() { echo -e "${RED}[error]${RESET} $*" >&2; }

# --- Argument parsing ---
COMMAND="${1:-}"
REMOTE_ARG=""

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      if [[ $# -lt 2 ]]; then
        error "--remote requires a value (e.g. user@host:~/.claude/)"
        exit 1
      fi
      REMOTE_ARG="$2"; shift 2 ;;
    *)
      error "Unknown argument: $1"
      exit 1 ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  error "Usage: cast-sync.sh <push|pull|status|config> [--remote user@host:~/.claude/]"
  exit 1
fi

# --- Config helpers ---
read_sync_config() {
  python3 -c "
import json
from pathlib import Path
f = Path('${SYNC_CONFIG}')
try:
  d = json.loads(f.read_text()) if f.exists() else {}
except Exception:
  d = {}
print(d.get('default_remote', ''))
" 2>/dev/null || echo ""
}

write_sync_config() {
  local key="$1"
  local value="$2"
  # Pass key and value as argv to avoid shell injection into Python source
  python3 - "$key" "$value" "$SYNC_CONFIG" <<'PYEOF' 2>/dev/null || warn "Failed to write sync config"
import json, sys
from pathlib import Path
key, value, config_path = sys.argv[1], sys.argv[2], sys.argv[3]
f = Path(config_path)
try:
  d = json.loads(f.read_text()) if f.exists() else {}
except Exception:
  d = {}
if not isinstance(d, dict):
  d = {}
d[key] = value
f.parent.mkdir(parents=True, exist_ok=True)
f.write_text(json.dumps(d, indent=2))
print(f"Saved {key} to sync config")
PYEOF
}

update_sync_timestamp() {
  local key="$1"
  # Pass key as argv to avoid injection
  python3 - "$key" "$SYNC_CONFIG" <<'PYEOF' 2>/dev/null || true
import json, sys, time
from pathlib import Path
key, config_path = sys.argv[1], sys.argv[2]
f = Path(config_path)
try:
  d = json.loads(f.read_text()) if f.exists() else {}
except Exception:
  d = {}
if not isinstance(d, dict):
  d = {}
d[key] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
f.parent.mkdir(parents=True, exist_ok=True)
f.write_text(json.dumps(d, indent=2))
PYEOF
}

# --- Determine remote ---
resolve_remote() {
  if [[ -n "$REMOTE_ARG" ]]; then
    echo "$REMOTE_ARG"
  else
    local default_remote
    default_remote="$(read_sync_config)"
    if [[ -z "$default_remote" ]]; then
      error "No remote configured. Use --remote user@host:~/.claude/ or run:"
      error "  cast-sync.sh config --remote user@host:~/.claude/"
      exit 1
    fi
    echo "$default_remote"
  fi
}

# --- Rsync include/exclude rules ---
# ALWAYS syncs: cast.db, cast/budget-today.json, projects/*/memory/, config/
# NEVER syncs:  cast/events/, cast/logs/, *.pid, *.state, *.log, *.sock
build_rsync_args() {
  echo "--compress"
  echo "--checksum"
  echo "--recursive"
  echo "--times"
  echo "--links"
  # Excludes — ephemeral files
  echo "--exclude=cast/events/"
  echo "--exclude=cast/logs/"
  echo "--exclude=cast/*.pid"
  echo "--exclude=cast/*.state"
  echo "--exclude=cast/*.log"
  echo "--exclude=cast/*.sock"
  echo "--exclude=*.pid"
  echo "--exclude=*.state"
  echo "--exclude=*.log"
  echo "--exclude=*.sock"
  echo "--exclude=briefings/"
  echo "--exclude=meetings/"
  # Includes — explicitly sync these
  echo "--include=cast.db"
  echo "--include=cast/budget-today.json"
  echo "--include=projects/"
  echo "--include=projects/*/memory/"
  echo "--include=projects/*/memory/**"
  echo "--include=config/"
  echo "--include=config/**"
  # Exclude everything else not matched
  echo "--filter=hide,! **/"
}

# --- Daemon pause/resume ---
daemon_running() {
  local state
  state="$(python3 -c "
import json
from pathlib import Path
f = Path('${CASTD_STATE_FILE}')
try:
  d = json.loads(f.read_text()) if f.exists() else {}
  print(d.get('status', 'stopped'))
except Exception:
  print('stopped')
" 2>/dev/null || echo "stopped")"
  [[ "$state" == "running" ]]
}

pause_daemon() {
  if [[ -f "$CASTD_PID_FILE" ]] && daemon_running; then
    local pid
    pid="$(cat "$CASTD_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill -STOP "$pid" 2>/dev/null || true
      info "Paused castd (PID $pid) during sync"
      echo "$pid"
      return
    fi
  fi
  echo ""
}

resume_daemon() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -CONT "$pid" 2>/dev/null || true
    info "Resumed castd (PID $pid)"
  fi
}

# --- Commands ---
cmd_config() {
  if [[ -n "$REMOTE_ARG" ]]; then
    write_sync_config "default_remote" "$REMOTE_ARG"
  else
    local current
    current="$(read_sync_config)"
    if [[ -n "$current" ]]; then
      info "default_remote: $current"
    else
      warn "No default remote configured"
      echo "Set one with: cast-sync.sh config --remote user@host:~/.claude/"
    fi
    if [[ -f "$SYNC_CONFIG" ]]; then
      echo ""
      cat "$SYNC_CONFIG"
    fi
  fi
}

cmd_status() {
  local remote
  remote="$(resolve_remote)"
  info "Dry-run status vs $remote"

  backup_dir="${CAST_DIR}/sync-backups/$(date +%Y%m%d)"
  mapfile -t rsync_args < <(build_rsync_args)

  rsync --dry-run --verbose \
    "${rsync_args[@]}" \
    "${CLAUDE_DIR}/" \
    "$remote" || warn "rsync returned non-zero (remote may be unreachable)"
}

cmd_push() {
  local remote
  remote="$(resolve_remote)"
  info "Pushing to $remote"

  local backup_dir="${CAST_DIR}/sync-backups/$(date +%Y%m%d)"
  mkdir -p "$backup_dir"

  mapfile -t rsync_args < <(build_rsync_args)

  # Pause daemon during push
  local paused_pid
  paused_pid="$(pause_daemon)"

  local exit_code=0
  rsync --verbose \
    --backup \
    "--backup-dir=${backup_dir}" \
    "${rsync_args[@]}" \
    "${CLAUDE_DIR}/" \
    "$remote" || exit_code=$?

  resume_daemon "$paused_pid"

  if [[ "$exit_code" -eq 0 ]]; then
    update_sync_timestamp "last_push"
    info "Push complete."
  else
    error "rsync exited with code $exit_code"
    exit "$exit_code"
  fi
}

cmd_pull() {
  local remote
  remote="$(resolve_remote)"
  info "Pull from $remote (dry-run first)"

  mapfile -t rsync_args < <(build_rsync_args)

  echo ""
  echo "--- Dry-run diff ---"
  rsync --dry-run --verbose \
    "${rsync_args[@]}" \
    "$remote" \
    "${CLAUDE_DIR}/" || { warn "rsync dry-run failed — aborting pull"; exit 1; }
  echo "--- End diff ---"
  echo ""

  printf "Apply pull? [y/N] "
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    warn "Pull cancelled."
    exit 0
  fi

  local backup_dir="${CAST_DIR}/sync-backups/$(date +%Y%m%d)-pull"
  mkdir -p "$backup_dir"

  local exit_code=0
  rsync --verbose \
    --backup \
    "--backup-dir=${backup_dir}" \
    "${rsync_args[@]}" \
    "$remote" \
    "${CLAUDE_DIR}/" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    update_sync_timestamp "last_pull"
    info "Pull complete."
  else
    error "rsync exited with code $exit_code"
    exit "$exit_code"
  fi
}

# --- Dispatch ---
case "$COMMAND" in
  push)   cmd_push ;;
  pull)   cmd_pull ;;
  status) cmd_status ;;
  config) cmd_config ;;
  *)
    error "Unknown command: $COMMAND"
    echo "Usage: cast-sync.sh <push|pull|status|config> [--remote user@host:~/.claude/]" >&2
    exit 1 ;;
esac
