#!/usr/bin/env bash
# cast-maintenance.sh — Periodic CAST cleanup
# Run daily via cron or weekly via scheduled task
set -euo pipefail

CAST_DIR="${HOME}/.claude"
DB="${CAST_DIR}/cast.db"
LOG="${CAST_DIR}/logs/maintenance.log"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG"; }

log "Starting maintenance run"

# 1. Mark stale running agents as failed (>2h old)
stale=$(sqlite3 "$DB" "SELECT COUNT(*) FROM agent_runs WHERE status='running' AND datetime(started_at) < datetime('now','-2 hours');" 2>/dev/null || echo 0)
if [ "$stale" -gt 0 ]; then
  sqlite3 "$DB" "UPDATE agent_runs SET status='failed', ended_at=datetime('now') WHERE status='running' AND datetime(started_at) < datetime('now','-2 hours');"
  log "Cleaned $stale stale running agents"
fi

# 2. Prune event files older than 30 days
pruned=$(find "${CAST_DIR}/cast/events/" -name "*.json" -mtime +30 -delete -print 2>/dev/null | wc -l | tr -d ' ')
log "Pruned $pruned event files (>30d)"

# 3. Prune agent-status files older than 7 days
pruned=$(find "${CAST_DIR}/agent-status/" -name "*.json" -mtime +7 -delete -print 2>/dev/null | wc -l | tr -d ' ')
log "Pruned $pruned status files (>7d)"

# 4. Prune git worktrees across project repos
for repo in ~/Projects/personal/claude-agent-team ~/Projects/personal/claude-code-dashboard ~/Projects/personal/project-engram; do
  if [ -d "$repo/.git" ]; then
    git -C "$repo" worktree prune 2>/dev/null
  fi
done
# Clean up orphaned swarm worktree dirs in /tmp
find /private/tmp -maxdepth 1 -name "cast-swarm-*" -type d -mtime +3 -exec rm -rf {} + 2>/dev/null
log "Pruned stale worktrees"

# 5. Aggregate session costs from agent_runs (backfill any gaps)
sqlite3 "$DB" "
UPDATE sessions SET
  total_cost_usd = COALESCE((SELECT SUM(cost_usd) FROM agent_runs WHERE agent_runs.session_id = sessions.id), 0.0)
WHERE (total_cost_usd = 0.0 OR total_cost_usd IS NULL)
AND id IN (SELECT DISTINCT session_id FROM agent_runs WHERE cost_usd > 0);
" 2>/dev/null
log "Backfilled session costs"

# 6. Rotate large log files (>5MB)
for logfile in "${CAST_DIR}"/logs/*.log; do
  if [ -f "$logfile" ] && [ "$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null)" -gt 5242880 ]; then
    tail -1000 "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
    log "Rotated $(basename "$logfile")"
  fi
done

log "Maintenance complete"
