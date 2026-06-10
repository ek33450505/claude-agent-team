#!/usr/bin/env bash
# cast-maintenance.sh — Periodic CAST cleanup
# Run daily via cron or weekly via scheduled task
set -euo pipefail

CAST_DIR="${HOME}/.claude"
DB="${CAST_DIR}/cast.db"
LOG="${CAST_DIR}/logs/maintenance.log"

# shellcheck source=cast-sqlite-lib.sh
CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${CAST_DIR}/scripts}"
# shellcheck disable=SC1091
source "${CAST_SCRIPTS_DIR}/cast-sqlite-lib.sh" 2>/dev/null || source "$(dirname "$0")/cast-sqlite-lib.sh" 2>/dev/null || true

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG"; }

log "Starting maintenance run"

# 1. Mark stale running agents as failed (>2h old)
stale=$(cast_sqlite "$DB" "SELECT COUNT(*) FROM agent_runs WHERE status='running' AND datetime(started_at) < datetime('now','-2 hours');" 2>/dev/null || echo 0)
if [ "$stale" -gt 0 ]; then
  cast_sqlite "$DB" "UPDATE agent_runs SET status='failed', ended_at=datetime('now') WHERE status='running' AND datetime(started_at) < datetime('now','-2 hours');"
  log "Cleaned $stale stale running agents"
fi

# 2. Prune event files older than 30 days (both .json and .jsonl.gz)
pruned=$(find "${CAST_DIR}/cast/events/" \( -name "*.json" -o -name "*.jsonl.gz" \) -mtime +30 -delete -print 2>/dev/null | wc -l | tr -d ' ')
log "Pruned $pruned event files (>30d)"

# 3. Prune agent-status files older than 24h (-mtime +0 means modified >24h ago)
pruned=$(find "${CAST_DIR}/agent-status/" -name "*.json" -mtime +0 -delete -print 2>/dev/null | wc -l | tr -d ' ')
log "Pruned $pruned status files (>24h)"

# 4. Prune git worktrees across project repos
for repo in ~/Projects/personal/claude-agent-team ~/Projects/personal/claude-code-dashboard; do
  if [ -d "$repo/.git" ]; then
    git -C "$repo" worktree prune 2>/dev/null
  fi
done
# Clean up orphaned swarm worktree dirs in /tmp
find /private/tmp -maxdepth 1 -name "cast-swarm-*" -type d -mtime +3 -exec rm -rf {} + 2>/dev/null
log "Pruned stale worktrees"

# 5. Aggregate session costs from agent_runs (backfill any gaps)
cast_sqlite "$DB" "
UPDATE sessions SET
  total_cost_usd = COALESCE((SELECT SUM(cost_usd) FROM agent_runs WHERE agent_runs.session_id = sessions.id), 0.0)
WHERE (total_cost_usd = 0.0 OR total_cost_usd IS NULL)
AND id IN (SELECT DISTINCT session_id FROM agent_runs WHERE cost_usd > 0);
" 2>/dev/null
log "Backfilled session costs"

# 6. Rotate large log files (>512KB)
for logfile in "${CAST_DIR}"/logs/*.log; do
  if [ -f "$logfile" ] && [ "$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null)" -gt 524288 ]; then
    tail -1000 "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
    log "Rotated $(basename "$logfile")"
  fi
done

# 7. Run agent memory staleness sweep
if [[ -f "${CAST_DIR}/scripts/cast-memory-staleness-sweep.sh" ]]; then
  bash "${CAST_DIR}/scripts/cast-memory-staleness-sweep.sh" >> "${CAST_DIR}/logs/staleness-sweep.log" 2>&1 || true
  log "Ran memory staleness sweep"
fi

# 8. Collect cookbook drift dispatch events
if [[ -f "${CAST_DIR}/scripts/cast-cookbook-drift.sh" ]]; then
  bash "${CAST_DIR}/scripts/cast-cookbook-drift.sh" >> "${CAST_DIR}/logs/cookbook-drift.log" 2>&1 || true
  log "Collected cookbook drift events"
fi

# 9. Snapshot Anthropic rate limits
if [[ -f "${CAST_DIR}/scripts/cast-rate-check.py" ]]; then
  python3 "${CAST_DIR}/scripts/cast-rate-check.py" >> "${CAST_DIR}/logs/rate-check.log" 2>&1 || true
  log "Recorded rate limit snapshot"
fi

log "Maintenance complete"
