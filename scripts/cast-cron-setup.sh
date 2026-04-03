#!/bin/bash
# cast-cron-setup.sh — Install/manage CAST scheduled cron entries
#
# Replaces castd.sh daemon with simple cron jobs.
#
# Scheduled tasks:
#   0 7  * * *   morning   — daily morning briefing at 07:00 (--agent morning-briefing)
#   0 18 * * *   summary   — daily agent summary at 18:00 (--agent docs)
#   0 9  * * 1   cost-report — weekly cost report at 09:00 Monday (--agent researcher)
#   0 3  * * *   tidy      — daily CAST cleanup at 03:00
#   30 3 * * *   db-prune  — prune old DB rows at 03:30
#   45 3 * * *   log-compress — compress old event logs at 03:45
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
# Each entry: "schedule|job_name|command"
# Agent tasks use claude --agent; raw shell tasks use the command directly.
declare -a CRON_ENTRIES=(
  "0 7 * * *|morning|claude --agent morning-briefing -p 'Generate today\\'s morning briefing' --max-turns 25 --permission-mode bypassPermissions"
  "0 18 * * *|summary|claude --agent docs -p 'Generate daily summary from cast.db: summarize agent_runs completed today, highlight BLOCKED or DONE_WITH_CONCERNS' --max-turns 15 --permission-mode bypassPermissions"
  "0 9 * * 1|cost-report|claude --agent researcher -p 'Generate weekly cost report from cast.db agent_runs: show total cost_usd by model, cost savings this week' --max-turns 15 --permission-mode bypassPermissions"
  "0 3 * * *|tidy|~/.local/bin/cast tidy"
  "30 3 * * *|db-prune|sqlite3 ~/.claude/cast.db \"DELETE FROM routing_events WHERE created_at < datetime('now', '-90 days'); DELETE FROM agent_runs WHERE started_at < datetime('now', '-90 days');\""
  "45 3 * * *|log-compress|find ~/.claude/cast/events -name '*.jsonl' -mtime +7 -exec gzip {} \\;"
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
  local command="$3"
  local log_file="${LOGS_DIR}/cron-${job_name}.log"
  echo "${schedule} ${command} >> \"${log_file}\" 2>&1 ${MARKER}:${job_name}"
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
