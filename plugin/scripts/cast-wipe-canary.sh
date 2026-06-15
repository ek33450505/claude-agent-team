#!/usr/bin/env bash
# cast-wipe-canary.sh — Forensic capture triggered when ~/.claude disappears
#
# Installed as a WatchPaths launchd agent (com.cast.wipe-canary).
# Fires on ANY file-system event under ~/.claude; exits immediately (exit 0)
# if the directory still exists — benign changes are the overwhelmingly common case.
#
# When ~/.claude is ABSENT: captures forensic evidence to an incident directory
# OUTSIDE the blast radius so the data survives the wipe:
#
#   ${CAST_INCIDENT_DIR:-$HOME/Library/Application Support/cast/incidents}/wipe-<UTC-timestamp>/
#     processes.txt    — ps auxww snapshot
#     open-files.txt   — lsof for current user (15-second timeout)
#     unified-log.txt  — macOS unified log, last 5 min, .claude events (20-second timeout)
#     manifest.txt     — incident summary + HOME/user/path metadata
#
# SAFETY INVARIANT: this script never creates ~/.claude, never writes inside it,
# never deletes anything. Pure read-and-capture only.
#
# Env overrides:
#   CAST_INCIDENT_DIR        Override parent dir for incident capture
#   CAST_CANARY_FAST_CAPTURE=1  Skip lsof + log show (for tests; writes stubs)
#
# Exit codes: always 0 (daemon-style; the incident dir carries the real signal)

# ── Subprocess guard (must come before set -euo pipefail) ─────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Fast path: ~/.claude still exists — this is a benign WatchPaths event ─────
# Check first, before doing anything expensive.
if [ -d "${HOME}/.claude" ]; then
  exit 0
fi

# ── Error logger — writes to ~/.claude/logs only if that path exists ──────────
# (blast radius: if ~/.claude is gone, that log is also gone — silently skip)
# shellcheck disable=SC2329  # defined per CAST hook convention; called on future error paths
_log_error() {
  local log_dir="${HOME}/.claude/logs"
  if [ -d "${log_dir}" ]; then
    printf '[%s] ERROR cast-wipe-canary: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
      >> "${log_dir}/hook-errors.log" 2>/dev/null || true
  fi
}

# ── Compute incident directory (outside ~/.claude blast radius) ───────────────
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
INCIDENT_BASE="${CAST_INCIDENT_DIR:-${HOME}/Library/Application Support/cast/incidents}"
INCIDENT_DIR="${INCIDENT_BASE}/wipe-${TIMESTAMP}"

if ! mkdir -p "${INCIDENT_DIR}" 2>/dev/null; then
  # Last resort: fall back to /tmp — still outside ~/.claude
  INCIDENT_DIR="/tmp/cast-wipe-canary-${TIMESTAMP}"
  mkdir -p "${INCIDENT_DIR}" 2>/dev/null || exit 0  # truly nowhere to write; exit cleanly
fi

# ── Helper: run a command with a wall-clock time limit ───────────────────────
# Spawns the command in a background subshell; a watchdog kills it after N seconds.
# Uses only POSIX-compatible shell builtins — no external `timeout` required.
# Always returns 0 (failures are non-fatal).
_capture_timed() {
  local limit_secs="$1"
  local out_file="$2"
  shift 2
  # Run command in background subshell; redirect stdout+stderr to out_file
  ( "$@" > "${out_file}" 2>&1 ) &
  local cmd_pid="$!"
  # Watchdog: sleep then kill if still running
  ( sleep "${limit_secs}" && kill "${cmd_pid}" 2>/dev/null ) &
  local wdog_pid="$!"
  # Wait for the command to finish (or be killed)
  wait "${cmd_pid}" 2>/dev/null || true
  # Clean up watchdog if the command already exited
  kill "${wdog_pid}" 2>/dev/null || true
  wait "${wdog_pid}" 2>/dev/null || true
}

# ── 1. Process snapshot (fast — no network I/O) ───────────────────────────────
ps auxww > "${INCIDENT_DIR}/processes.txt" 2>/dev/null || true

# ── 2. Open files for current user (bounded to 15 s) ─────────────────────────
if [ "${CAST_CANARY_FAST_CAPTURE:-0}" = "1" ]; then
  printf '[CAST_CANARY_FAST_CAPTURE=1: lsof skipped]\n' \
    > "${INCIDENT_DIR}/open-files.txt"
else
  _capture_timed 15 "${INCIDENT_DIR}/open-files.txt" \
    lsof -n -u "$(id -un 2>/dev/null || echo root)"
fi

# ── 3. macOS unified log — last 5 minutes, events mentioning .claude ─────────
if [ "${CAST_CANARY_FAST_CAPTURE:-0}" = "1" ]; then
  printf '[CAST_CANARY_FAST_CAPTURE=1: log show skipped]\n' \
    > "${INCIDENT_DIR}/unified-log.txt"
else
  _capture_timed 20 "${INCIDENT_DIR}/unified-log.txt" \
    log show --last 5m --predicate 'eventMessage CONTAINS ".claude"'
fi

# ── 4. Manifest ───────────────────────────────────────────────────────────────
{
  printf 'cast-wipe-canary incident report\n'
  printf '================================\n'
  printf 'timestamp:            %s\n' "${TIMESTAMP}"
  printf 'home:                 %s\n' "${HOME}"
  printf 'user:                 %s\n' "$(id -un 2>/dev/null || echo unknown)"
  printf 'claude_dir_exists:    no\n'
  if [ -d "${HOME}/.claude/scripts" ]; then
    printf 'scripts_dir_exists:   yes\n'
  else
    printf 'scripts_dir_exists:   no\n'
  fi
  # Shell history: note the typical paths for the investigator; never read the file
  # shellcheck disable=SC2016  # intentional: literal '$HISTFILE' as a human-readable hint
  printf 'shell_history_hint:   check $HISTFILE, ~/.bash_history, ~/.zsh_history\n'
  printf 'incident_dir:         %s\n' "${INCIDENT_DIR}"
  printf 'fast_capture:         %s\n' "${CAST_CANARY_FAST_CAPTURE:-0}"
} > "${INCIDENT_DIR}/manifest.txt" 2>/dev/null || true

# ── 5. Desktop notification (macOS; best-effort) ──────────────────────────────
if command -v osascript > /dev/null 2>&1; then
  # Sanitize path for AppleScript string embedding (backslash + double-quote only)
  _safe_path="$(printf '%s' "${INCIDENT_DIR}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  osascript 2>/dev/null <<APPLESCRIPT || true
display notification "Evidence captured at: ${_safe_path}" with title "CAST: ~/.claude WIPE DETECTED" sound name "Bottle"
APPLESCRIPT
fi

exit 0
