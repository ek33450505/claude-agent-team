#!/usr/bin/env bash
# cast-backup-scheduled.sh — Orchestrate on-disk snapshot + best-effort overlay push
#
# Entry point for the daily launchd job (com.cast.backup).
# Runs as the user (not as a Claude Code agent), so it has legitimate access to gh/ssh auth.
#
# Step 1: Take an on-disk snapshot (must succeed)
# Step 2: Push overlay to cast-private repo (best-effort; non-fatal failure)
#
# Exit status: Always 0 (daemon-style logging). Per-step success/failure is recorded in the log.

set -uo pipefail

# Resolve scripts directory
SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"

# Ensure log directory exists
LOGS_DIR="${HOME}/.claude/logs"
mkdir -p "$LOGS_DIR"

LOG_FILE="${LOGS_DIR}/cast-backup-scheduled.log"

# Timestamp function
_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Log a message with timestamp
_log() {
  echo "$(_ts) $*" >> "$LOG_FILE"
}

_log "=== Starting scheduled backup run ==="

# Step 1: On-disk snapshot (must succeed)
_log "Step 1: Running on-disk snapshot..."
if python3 "${SCRIPTS_DIR}/cast-snapshot.py" >> "$LOG_FILE" 2>&1; then
  _log "Step 1: On-disk snapshot SUCCEEDED"
  SNAPSHOT_OK=1
else
  _log "Step 1: On-disk snapshot FAILED (exit code: $?)"
  SNAPSHOT_OK=0
fi

# Step 2: Overlay push (best-effort, non-fatal)
_log "Step 2: Running overlay push..."
if bash "${SCRIPTS_DIR}/cast-overlay-sync.sh" >> "$LOG_FILE" 2>&1; then
  _log "Step 2: Overlay push SUCCEEDED"
  OVERLAY_OK=1
else
  _log "Step 2: Overlay push FAILED or SKIPPED (check gh/ssh auth in launchd environment). See log above for details."
  OVERLAY_OK=0
fi

# Final summary
_log "=== Backup run complete ==="
if [[ $SNAPSHOT_OK -eq 1 ]]; then
  _log "SUMMARY: Snapshot succeeded. Overlay: $([ $OVERLAY_OK -eq 1 ] && echo 'succeeded' || echo 'failed/skipped (non-fatal)')"
else
  _log "SUMMARY: Snapshot FAILED — this is a hard error. Overlay status: $([ $OVERLAY_OK -eq 1 ] && echo 'succeeded' || echo 'unknown')"
fi

# Always exit 0 (daemon-style; the log carries the real status)
exit 0
