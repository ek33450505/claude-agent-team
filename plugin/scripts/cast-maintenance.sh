#!/usr/bin/env bash
# cast-maintenance.sh — Periodic CAST cleanup
# Run daily via cron or weekly via scheduled task
set -euo pipefail

CAST_DIR="${HOME}/.claude"
DB="${CAST_DIR}/cast.db"
LOG="${CAST_DIR}/logs/maintenance.log"

# shellcheck source=cast-sqlite-lib.sh
CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${CAST_DIR}/scripts}"
# Existence-checked before sourcing (do NOT collapse to
# `source X 2>/dev/null || source Y 2>/dev/null || true`): under `set -e`, bash 3.2
# treats `source` of a missing file as fatal even left-of-`||` — see cast-guard-lib.sh header.
_cast_sqlite_lib="${CAST_SCRIPTS_DIR}/cast-sqlite-lib.sh"
[[ -f "$_cast_sqlite_lib" ]] || _cast_sqlite_lib="$(dirname "$0")/cast-sqlite-lib.sh"
if [[ -f "$_cast_sqlite_lib" ]]; then
  # shellcheck source=cast-sqlite-lib.sh disable=SC1091
  source "$_cast_sqlite_lib" 2>/dev/null || true
fi
_cast_guard_lib="${CAST_SCRIPTS_DIR}/cast-guard-lib.sh"
[[ -f "$_cast_guard_lib" ]] || _cast_guard_lib="$(dirname "$0")/cast-guard-lib.sh"
if [[ -f "$_cast_guard_lib" ]]; then
  # shellcheck source=cast-guard-lib.sh disable=SC1091
  source "$_cast_guard_lib" 2>/dev/null || true
fi

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG"; }


# ---------------------------------------------------------------------------
# Source guard: allow tests to load the functions above without running the
# main execution body. Byte-identical launchd behavior when executed directly.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  # shellcheck disable=SC2317  # reachable when sourced: top-level return is valid there; || true guards the executed-context edge
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Main execution (only runs when executed, not when sourced)
# ---------------------------------------------------------------------------

log "Starting maintenance run"

# 1. Mark stale running agents as failed (>2h old)
stale=$(cast_sqlite "$DB" "SELECT COUNT(*) FROM agent_runs WHERE status='running' AND datetime(started_at) < datetime('now','-2 hours');" 2>/dev/null || echo 0)
if [ "$stale" -gt 0 ]; then
  cast_sqlite "$DB" "UPDATE agent_runs SET status='failed', ended_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE status='running' AND datetime(started_at) < datetime('now','-2 hours');"
  log "Cleaned $stale stale running agents"
fi

# 1b. Mark stale running swarm sessions as ended (>1 day old)
stale_swarms=$(cast_sqlite "$DB" "SELECT COUNT(*) FROM swarm_sessions WHERE status='running' AND datetime(started_at) < datetime('now','-1 day');" 2>/dev/null || echo 0)
if [ "$stale_swarms" -gt 0 ]; then
  cast_sqlite "$DB" "UPDATE swarm_sessions SET status='ended', ended_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE status='running' AND datetime(started_at) < datetime('now','-1 day');"
  log "Closed $stale_swarms stale swarm sessions"
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
log "Pruned stale worktrees"

# 5. sessions.total_cost_usd dropped in migration 022 (wave-3); backfill removed

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
  log "Ran rate-limit check (see logs/rate-check.log)"
fi

# 9.5 Index new memory/incident/distillate rows into record_fts so fresh facts become injectable
if [[ -f "${CAST_DIR}/scripts/cast-ask-index.py" ]]; then
  for _k in memory incident distillate; do
    python3 "${CAST_DIR}/scripts/cast-ask-index.py" --kind "$_k" >> "${CAST_DIR}/logs/ask-index.log" 2>&1 || true
  done
  log "Indexed injection kinds into record_fts (see logs/ask-index.log)"
fi

# 10. Embed pending record_fts rows for semantic search (local Ollama; fail-open if not running)
if [[ -f "${CAST_DIR}/scripts/cast-ask-index.py" ]]; then
  python3 "${CAST_DIR}/scripts/cast-ask-index.py" --embed >> "${CAST_DIR}/logs/ask-embed.log" 2>&1 || true
  log "Ran record_embed pass (see logs/ask-embed.log)"
fi

log "Maintenance complete"
