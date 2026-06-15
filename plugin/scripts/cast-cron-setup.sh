#!/bin/bash
# cast-cron-setup.sh — Install/manage CAST scheduled cron entries
#
# Replaces castd.sh daemon with simple cron jobs.
#
# Each cron entry delegates to a generated script under ${HOME}/.cast/cron/<name>.sh
# rather than inlining commands directly in the crontab. This eliminates the class
# of cron-line injection that arises when agent prompt strings are embedded inline.
#
# Scheduled tasks:
#   0 7  * * *   morning   — daily morning briefing at 07:00 (--agent morning-briefing)
#   0 18 * * *   summary   — daily agent summary at 18:00 (--agent docs)
#   0 3  * * *   tidy      — daily CAST cleanup at 03:00
#   30 3 * * *   db-prune  — prune old DB rows at 03:30
#   45 3 * * *   log-compress — compress old event logs at 03:45
#   47 3  * * *  cast-maintenance — daily CAST maintenance at 03:47
#   0 8  * * 0   cron-health — weekly cron job health check on Sunday 08:00
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
CRON_SCRIPTS_DIR="${HOME}/.cast/cron"
MARKER="# CAST-MANAGED"

# Ensure directories exist
mkdir -p "$LOGS_DIR"
mkdir -p "$CRON_SCRIPTS_DIR"

# ── Cron entry definitions ────────────────────────────────────────────────────
# Each entry: "schedule|job_name"
# The actual command for each job is defined in _write_cron_script() below.
# Agent tasks are NOT inlined here — they live in generated script files.
declare -a CRON_ENTRIES=(
  "0 7 * * *|morning"
  "0 18 * * *|summary"
  "0 3 * * *|tidy"
  "30 3 * * *|db-prune"
  "45 3 * * *|log-compress"
  "47 3 * * *|cast-maintenance"
  "0 8 * * 0|cron-health"
)

# ── Write the per-job script file ─────────────────────────────────────────────
# Each job gets its own executable script under ${HOME}/.cast/cron/<name>.sh.
# The crontab entry just calls: bash ${HOME}/.cast/cron/<name>.sh
# This prevents any prompt string or path from being interpolated into a cron line.
_write_cron_script() {
  local job_name="$1"
  local script_file="${CRON_SCRIPTS_DIR}/${job_name}.sh"

  case "$job_name" in
    morning)
      cat > "$script_file" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
exec /opt/homebrew/bin/claude \
  --agent morning-briefing \
  --max-turns 25 \
  --permission-mode bypassPermissions \
  -p "Generate today's morning briefing"
SCRIPT
      ;;
    summary)
      cat > "$script_file" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
exec /opt/homebrew/bin/claude \
  --agent docs \
  --max-turns 15 \
  --permission-mode bypassPermissions \
  -p "Generate daily summary from cast.db: summarize agent_runs completed today, highlight BLOCKED or DONE_WITH_CONCERNS"
SCRIPT
      ;;
    tidy)
      cat > "$script_file" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
exec "${HOME}/.local/bin/cast" tidy
SCRIPT
      ;;
    db-prune)
      cat > "$script_file" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
exec python3 "${HOME}/.claude/scripts/cast-db-prune.py"
SCRIPT
      ;;
    log-compress)
      cat > "$script_file" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
find "${HOME}/.claude/cast/events" -name '*.jsonl' -mtime +7 -exec gzip {} \;
SCRIPT
      ;;
    cast-maintenance)
      cat > "$script_file" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
exec bash "${HOME}/.claude/scripts/cast-maintenance.sh"
SCRIPT
      ;;
    cron-health)
      cat > "$script_file" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
exec bash "${HOME}/.claude/scripts/cast-cron-health.sh"
SCRIPT
      ;;
    *)
      echo "cast-cron-setup: unknown job name: '${job_name}'" >&2
      return 1
      ;;
  esac

  chmod +x "$script_file"
}

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '^#!' | sed 's/^# \?//' | sed -n '/Usage:/,/^$/p'
  exit 0
}

# ── Build the cron line for a given entry ─────────────────────────────────────
# The crontab line delegates to the per-job script; no inline command or prompt.
make_cron_line() {
  local schedule="$1"
  local job_name="$2"
  local log_file="${LOGS_DIR}/cron-${job_name}.log"
  local script_file="${CRON_SCRIPTS_DIR}/${job_name}.sh"
  echo "${schedule} bash ${script_file} >> \"${log_file}\" 2>&1 ${MARKER}:${job_name}"
}

# ── List installed CAST cron entries ─────────────────────────────────────────
cmd_list() {
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || echo "")

  echo "CAST cron entries:"
  echo "══════════════════"

  local found=0
  for entry in "${CRON_ENTRIES[@]}"; do
    IFS='|' read -r schedule job_name <<< "$entry"
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

  # Ensure PATH header is present (idempotent)
  local new_crontab
  if echo "$current_crontab" | grep -qE "^(SHELL=|PATH=)"; then
    # Header already present; use crontab as-is
    new_crontab="$current_crontab"
  else
    # Insert PATH header at the top
    new_crontab="SHELL=/bin/zsh"$'\n'"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"$'\n'
    if [[ -n "$current_crontab" ]]; then
      new_crontab+=$'\n'"${current_crontab}"
    fi
  fi

  for entry in "${CRON_ENTRIES[@]}"; do
    IFS='|' read -r schedule job_name <<< "$entry"

    # Always (re)write the script file to keep it current
    _write_cron_script "$job_name"

    local cron_line
    cron_line=$(make_cron_line "$schedule" "$job_name")

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
      echo "  removed: ${line##*"${MARKER}":}"
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
