#!/bin/bash
# cast-cron-health.sh — Periodic cron job health check
#
# Scans cron job logs for failures and compares live crontab against expected entries.
# Writes health status to ~/.claude/logs/cron-health.log and alerts to cron-health-alerts.log.
#
# Exit codes:
#   0 = success (all checks passed, or logged warnings only)
#
# Usage:
#   cast-cron-health.sh    Run a single health check (safe for cron)

# ── Subprocess guard ──────────────────────────────────────────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
LOGS_DIR="${HOME}/.claude/logs"
HEALTH_LOG="${LOGS_DIR}/cron-health.log"
ALERTS_LOG="${LOGS_DIR}/cron-health-alerts.log"
ERRORS_LOG="${LOGS_DIR}/hook-errors.log"

# Ensure directories exist
mkdir -p "$LOGS_DIR"

# ── Error logging ─────────────────────────────────────────────────────────────
_log_error() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$ERRORS_LOG"
  echo "$msg" >&2
}

# ── Scan logs for failure markers in the last 7 days ──────────────────────────
_check_recent_failures() {
  local failure_count=0
  local failure_details=""

  # Find cron-*.log files modified in last 7 days
  if [[ ! -d "$LOGS_DIR" ]]; then
    return 0
  fi

  while IFS= read -r logfile; do
    # Scan for known error markers
    if grep -E "(command not found|No such file|Permission denied|error:|Error:|ERROR:)" "$logfile" > /dev/null 2>&1; then
      local basename
      basename=$(basename "$logfile")
      failure_count=$((failure_count + 1))
      failure_details+=$'\n'"  - $basename contains error markers"
    fi
  done < <(find "$LOGS_DIR" -name "cron-*.log" -mtime -7 2>/dev/null || true)

  echo "$failure_count"
  [[ -n "$failure_details" ]] && echo "$failure_details"
}

# ── Compare live crontab against expected entries ─────────────────────────────
_check_crontab_drift() {
  local drift_count=0
  local drift_details=""

  # Expected CAST-MANAGED entries (from setup script)
  local expected_entries=(
    "morning"
    "summary"
    "tidy"
    "db-prune"
    "log-compress"
    "pa-backup"
    "cast-maintenance"
    "cron-health"
  )

  # Get current crontab
  local current
  current=$(crontab -l 2>/dev/null || echo "")

  # Check for drift
  for entry_name in "${expected_entries[@]}"; do
    if ! echo "$current" | grep -qF "CAST-MANAGED:${entry_name}"; then
      drift_details+=$'\n'"  - Missing entry: ${entry_name}"
      drift_count=$((drift_count + 1))
    fi
  done

  # Check for unexpected untagged entries (only warn on cast-maintenance-like patterns)
  if echo "$current" | grep -E "^\s*[0-9].*bash ~/.claude/scripts" | grep -qv "CAST-MANAGED"; then
    drift_details+=$'\n'"  - Found untagged cron entries (should have # CAST-MANAGED comment)"
    drift_count=$((drift_count + 1))
  fi

  echo "$drift_count"
  [[ -n "$drift_details" ]] && echo "$drift_details"
}

# ── Main health check ─────────────────────────────────────────────────────────
main() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  local health_report=""
  local alert_triggered=0

  # Header
  health_report+=$'─ CRON HEALTH CHECK ─ '"${timestamp}"$'\n'

  # Check for recent failures
  local failure_output
  failure_output=$(_check_recent_failures)
  local failure_count
  failure_count=$(echo "$failure_output" | head -1)
  failure_details=$(echo "$failure_output" | tail -n +2 || true)

  if [[ "$failure_count" -gt 0 ]]; then
    health_report+=$'FAILURES DETECTED (last 7 days): '"${failure_count}"$'\n'
    health_report+="$failure_details"$'\n'
    alert_triggered=1
  else
    health_report+="No recent failure markers in cron logs."$'\n'
  fi

  health_report+=$'\n'

  # Check for crontab drift
  local drift_output
  drift_output=$(_check_crontab_drift)
  local drift_count
  drift_count=$(echo "$drift_output" | head -1)
  drift_details=$(echo "$drift_output" | tail -n +2 || true)

  if [[ "$drift_count" -gt 0 ]]; then
    health_report+=$'DRIFT DETECTED: '"${drift_count}"$' issue(s)'$'\n'
    health_report+="$drift_details"$'\n'
    alert_triggered=1
  else
    health_report+="Crontab entries match expected CAST-MANAGED set."$'\n'
  fi

  health_report+=$'\n'

  # Verify PATH header is present
  local crontab_top
  crontab_top=$(crontab -l 2>/dev/null | head -1 || echo "")
  if [[ "$crontab_top" == "SHELL="* ]]; then
    health_report+="Crontab PATH header: OK"$'\n'
  else
    health_report+="WARNING: Crontab missing SHELL/PATH header"$'\n'
    alert_triggered=1
  fi

  # Write health log
  {
    echo "$health_report"
    echo ""
  } >> "$HEALTH_LOG"

  # Write alert if issues found
  if [[ $alert_triggered -eq 1 ]]; then
    echo "[ALERT] ${timestamp} — Cron health check failed. See $HEALTH_LOG" >> "$ALERTS_LOG"
  fi

  return 0
}

main
