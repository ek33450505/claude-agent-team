#!/bin/bash
# cast-weekly-tuner.sh — Auto-tune CAST config based on weekly report data
# Reads cast.db directly for the trailing 7-day window.
# - Agent fails >30%: appends warning to agent .md definition file
# - Total spend > budget: emits [CAST-BUDGET-WARN] to stderr
# - Logs tuning actions to ~/.claude/cast/tuning-log.jsonl
#
# Usage:
#   cast-weekly-tuner.sh
#
# Environment:
#   CAST_DB_PATH         — override default cast.db location (default: ~/.claude/cast.db)
#   CAST_WEEKLY_BUDGET   — weekly spend threshold in USD (default: 10.00)

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
AGENTS_DIR="${HOME}/.claude/agents"
TUNING_LOG="${HOME}/.claude/cast/tuning-log.jsonl"
BUDGET_USD="${CAST_WEEKLY_BUDGET:-10.00}"
WEEK_START=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)
TODAY=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$TUNING_LOG")"

# Check db is available and has agent_runs table
if [ ! -f "$DB_PATH" ] || ! sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_runs';" 2>/dev/null | grep -q agent_runs; then
  echo "[cast-weekly-tuner] cast.db not available — skipping tuning" >&2
  exit 0
fi

q() { sqlite3 "$DB_PATH" "$1" 2>/dev/null || echo ""; }

log_action() {
  local action="$1" detail="$2"
  printf '{"timestamp":"%s","action":"%s","detail":"%s"}\n' "$TODAY" "$action" "$detail" >> "$TUNING_LOG"
}

# --- Check total weekly spend vs budget ---
TOTAL_COST=$(q "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs WHERE started_at >= '${WEEK_START}';")
if python3 -c "import sys; sys.exit(0 if float('${TOTAL_COST}') > float('${BUDGET_USD}') else 1)" 2>/dev/null; then
  echo "[CAST-BUDGET-WARN] Weekly spend \$${TOTAL_COST} exceeds budget \$${BUDGET_USD}" >&2
  log_action "budget_warn" "spend=${TOTAL_COST} budget=${BUDGET_USD}"
fi

# --- Check agent failure rates (only agents with >= 3 runs) ---
q "SELECT agent, COUNT(*) as total,
   SUM(CASE WHEN status IN ('BLOCKED','failed') THEN 1 ELSE 0 END) as failures
   FROM agent_runs
   WHERE started_at >= '${WEEK_START}'
   GROUP BY agent
   HAVING total >= 3;" | while IFS='|' read -r agent total failures; do
  [ -z "$agent" ] && continue
  fail_pct=$(python3 -c "print(int(${failures:-0} / max(${total:-1},1) * 100))" 2>/dev/null || echo 0)
  if [ "${fail_pct}" -gt 30 ] 2>/dev/null; then
    agent_file="${AGENTS_DIR}/${agent}.md"
    if [ -f "$agent_file" ]; then
      # Only append warning if not already present for this week
      if ! grep -q "CAST-TUNER-WARN.*${WEEK_START}" "$agent_file" 2>/dev/null; then
        printf '\n> **[CAST-TUNER-WARN %s]** Failure rate %d%% this week (%s/%s runs failed). Review agent instructions.\n' \
          "$WEEK_START" "$fail_pct" "$failures" "$total" >> "$agent_file"
        log_action "agent_warned" "agent=${agent} fail_pct=${fail_pct}"
        echo "[cast-weekly-tuner] Warned ${agent}: ${fail_pct}% failure rate" >&2
      fi
    fi
  fi
done

echo "[cast-weekly-tuner] tuning complete" >&2
