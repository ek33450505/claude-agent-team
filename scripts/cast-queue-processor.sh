#!/bin/bash
# cast-queue-processor.sh — Poll task_queue and dispatch pending agents
# Intended to run via cron every minute.
# Usage: bash cast-queue-processor.sh
#
# Picks one pending row, marks it running, dispatches via cast-exec.sh,
# then marks done or failed based on exit code.
# Guards against double-dispatch by marking 'running' before exec.

set +e

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
CAST_EXEC="${HOME}/.claude/scripts/cast-exec.sh"
LOG="${HOME}/.claude/logs/queue-processor.log"
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

[ -f "$DB_PATH" ] || exit 0
[ -f "$CAST_EXEC" ] || exit 0

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Claim one pending row atomically
ROW="$(sqlite3 "$DB_PATH" \
  "SELECT id, agent, task, priority FROM task_queue WHERE status='pending' ORDER BY priority ASC, created_at ASC LIMIT 1;" \
  2>/dev/null)"

[ -z "$ROW" ] && exit 0

TASK_ID="$(echo "$ROW" | cut -d'|' -f1)"
AGENT_TYPE="$(echo "$ROW" | cut -d'|' -f2)"
TASK_TEXT="$(echo "$ROW" | cut -d'|' -f3)"

# Mark as running atomically (only if still pending — prevents double-dispatch)
ROWS_UPDATED="$(sqlite3 "$DB_PATH" \
  "UPDATE task_queue SET status='claimed', claimed_at='${TIMESTAMP}' WHERE id=${TASK_ID} AND status='pending'; SELECT changes();" \
  2>/dev/null | tail -1)"

if [ "${ROWS_UPDATED:-0}" -eq 0 ]; then
  # Another process claimed this row — exit cleanly
  exit 0
fi

echo "[${TIMESTAMP}] Dispatching ${AGENT_TYPE} (task_id=${TASK_ID}): ${TASK_TEXT}" >> "$LOG"

# Dispatch via cast-exec
bash "$CAST_EXEC" "$AGENT_TYPE" "$TASK_TEXT" >> "$LOG" 2>&1
EXIT_CODE=$?

DONE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ $EXIT_CODE -eq 0 ]; then
  sqlite3 "$DB_PATH" \
    "UPDATE task_queue SET status='done', completed_at='${DONE_TS}' WHERE id=${TASK_ID};" \
    2>/dev/null || true
  echo "[${DONE_TS}] task_id=${TASK_ID} completed (exit 0)" >> "$LOG"
else
  RETRY_COUNT="$(sqlite3 "$DB_PATH" \
    "SELECT retry_count FROM task_queue WHERE id=${TASK_ID};" \
    2>/dev/null || echo 0)"
  MAX_RETRIES="$(sqlite3 "$DB_PATH" \
    "SELECT max_retries FROM task_queue WHERE id=${TASK_ID};" \
    2>/dev/null || echo 3)"

  if [ "${RETRY_COUNT:-0}" -lt "${MAX_RETRIES:-3}" ]; then
    # Requeue for retry
    sqlite3 "$DB_PATH" \
      "UPDATE task_queue SET status='pending', retry_count=retry_count+1, claimed_at=NULL WHERE id=${TASK_ID};" \
      2>/dev/null || true
    echo "[${DONE_TS}] task_id=${TASK_ID} failed (exit ${EXIT_CODE}), requeued (retry $((RETRY_COUNT+1))/${MAX_RETRIES})" >> "$LOG"
  else
    sqlite3 "$DB_PATH" \
      "UPDATE task_queue SET status='failed', completed_at='${DONE_TS}' WHERE id=${TASK_ID};" \
      2>/dev/null || true
    echo "[${DONE_TS}] task_id=${TASK_ID} failed after ${MAX_RETRIES} retries — marked failed" >> "$LOG"
  fi
fi
