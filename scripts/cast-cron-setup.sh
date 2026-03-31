#!/bin/bash
# cast-cron-setup.sh — Install/manage CAST scheduled cron entries
#
# Replaces castd.sh daemon with simple cron jobs.
#
# Scheduled tasks:
#   0 7  * * *   morning-briefing   — daily morning briefing at 07:00
#   0 18 * * *   chain-reporter     — daily agent summary at 18:00
#   0 9  * * 1   report-writer      — weekly cost report at 09:00 Monday
#
# Usage:
#   cast-cron-setup.sh           Install missing cron entries (idempotent)
#   cast-cron-setup.sh --list    Show which CAST cron entries are installed
#   cast-cron-setup.sh --remove  Remove all CAST cron entries
#   cast-cron-setup.sh --help    Show this help
#
# Log output: ~/.claude/logs/cron-<job>.log

# ── Subprocess guard ──────────────────────────────────────────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
LOGS_DIR="${HOME}/.claude/logs"
MARKER="# CAST-MANAGED"

# Ensure log directory exists
mkdir -p "$LOGS_DIR"

# ── Cron entry definitions ────────────────────────────────────────────────────
# Each entry: "schedule|job_name|prompt"
# claude -p runs Claude Code in headless (non-interactive) mode.
declare -a CRON_ENTRIES=(
  "0 7 * * *|morning|Generate morning briefing: summarize pending tasks, recent agent activity, and priorities for today"
  "0 18 * * *|summary|Generate daily summary: summarize all agent_runs completed today from cast.db, highlight any BLOCKED or DONE_WITH_CONCERNS statuses"
  "0 9 * * 1|cost-report|Generate weekly cost report from cast.db agent_runs: show total cost_usd by model, local vs cloud split, cost savings this week"
  "0 * * * *|sweep|cast exec --sweep"
  "30 3 * * *|db-prune|sqlite3 ~/.claude/cast.db \"DELETE FROM routing_events WHERE created_at < datetime('now', '-90 days'); DELETE FROM agent_runs WHERE started_at < datetime('now', '-90 days');\""
  "45 3 * * *|log-compress|find ~/.claude/cast/events -name '*.jsonl' -mtime +7 -exec gzip {} \\;"
  "0 10 * * 0|security-audit|Run a security audit of the CAST scripts and agent definitions. Check for hardcoded secrets, overly permissive file operations, and injection risks. Save report to ~/.claude/reports/security-$(date +\%Y-\%m-\%d).md"
  "30 10 * * 0|weekly-report|Generate a weekly agent performance report from cast.db. Include: top agents by run count, average duration per agent, error rates, token spend by agent. Save to ~/.claude/briefings/weekly-$(date +\%Y-\%m-\%d).md"
  "*/5 * * * *|resume-watcher|Check ~/.claude/cast/resume-queue/ for pending orchestrator resume requests and dispatch a new orchestrator session if any are found"
)

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '^#!' | sed 's/^# \?//' | sed -n '/Usage:/,/^$/p'
  exit 0
}

# ── Build the cron line for a given entry ─────────────────────────────────────
make_cron_line() {
  local schedule="$1"
  local job_name="$2"
  local prompt="$3"
  local log_file="${LOGS_DIR}/cron-${job_name}.log"
  echo "${schedule} claude -p \"${prompt}\" >> \"${log_file}\" 2>&1 ${MARKER}:${job_name}"
}

# ── List installed CAST cron entries ─────────────────────────────────────────
cmd_list() {
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || echo "")

  echo "CAST cron entries:"
  echo "══════════════════"

  local found=0
  for entry in "${CRON_ENTRIES[@]}"; do
    IFS='|' read -r schedule job_name prompt <<< "$entry"
    if echo "$current_crontab" | grep -qF "${MARKER}:${job_name}"; then
      echo "  installed   ${job_name}  (${schedule})"
      found=$((found + 1))
    else
      echo "  missing     ${job_name}  (${schedule})"
    fi
  done

  echo "══════════════════"
  echo "  ${found}/${#CRON_ENTRIES[@]} installed"
}

# ── Install missing cron entries (idempotent) ─────────────────────────────────
cmd_install() {
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || echo "")

  local added=0
  local skipped=0
  local new_crontab="$current_crontab"

  for entry in "${CRON_ENTRIES[@]}"; do
    IFS='|' read -r schedule job_name prompt <<< "$entry"
    local cron_line
    cron_line=$(make_cron_line "$schedule" "$job_name" "$prompt")

    if echo "$current_crontab" | grep -qF "${MARKER}:${job_name}"; then
      echo "  skipped (already installed): ${job_name}"
      skipped=$((skipped + 1))
    else
      # Append the new entry
      if [[ -n "$new_crontab" ]]; then
        new_crontab="${new_crontab}"$'\n'"${cron_line}"
      else
        new_crontab="${cron_line}"
      fi
      echo "  added: ${job_name}  (${schedule})"
      added=$((added + 1))
    fi
  done

  if [[ $added -gt 0 ]]; then
    echo "$new_crontab" | crontab -
    echo "Crontab updated — ${added} entr$([ "$added" -eq 1 ] && echo 'y' || echo 'ies') added, ${skipped} already present."
  else
    echo "All CAST cron entries already installed — no changes made."
  fi
}

# ── Remove all CAST cron entries ──────────────────────────────────────────────
cmd_remove() {
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || echo "")

  if ! echo "$current_crontab" | grep -qF "$MARKER"; then
    echo "No CAST cron entries found — nothing to remove."
    exit 0
  fi

  local removed=0
  local new_crontab=""

  while IFS= read -r line; do
    if echo "$line" | grep -qF "$MARKER"; then
      removed=$((removed + 1))
      echo "  removed: ${line##*${MARKER}:}"
    else
      if [[ -n "$new_crontab" ]]; then
        new_crontab="${new_crontab}"$'\n'"${line}"
      else
        new_crontab="${line}"
      fi
    fi
  done <<< "$current_crontab"

  if [[ -n "$new_crontab" ]]; then
    echo "$new_crontab" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi

  echo "Removed ${removed} CAST cron entr$([ "$removed" -eq 1 ] && echo 'y' || echo 'ies')."
}

# ── Argument dispatch ─────────────────────────────────────────────────────────
case "${1:-}" in
  --help|-h)
    usage
    ;;
  --list|-l)
    cmd_list
    ;;
  --remove|-r)
    cmd_remove
    ;;
  "")
    cmd_install
    ;;
  *)
    echo "Unknown flag: ${1}" >&2
    echo "Run with --help for usage." >&2
    exit 1
    ;;
esac
