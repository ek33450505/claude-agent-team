#!/bin/bash
# cast-resume-watcher.sh — Check resume-queue and dispatch orchestrator to resume
#
# Runs every 5 minutes via cron (installed by cast-cron-setup.sh).
# Picks the oldest pending resume-request file from ~/.claude/cast/resume-queue/,
# moves it to processed/, and invokes claude -p to resume the orchestrator run.
#
# Only processes one file per run to avoid parallel orchestrator sessions.
#
# Log output: ~/.claude/logs/cron-resume-watcher.log

# ── Subprocess guard ──────────────────────────────────────────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set +e

RESUME_DIR="${HOME}/.claude/cast/resume-queue"
PROCESSED_DIR="${RESUME_DIR}/processed"
LOG_FILE="${HOME}/.claude/logs/cron-resume-watcher.log"

mkdir -p "$PROCESSED_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Find oldest .json file (ls -t sorts newest-first; tail -1 gives oldest)
OLDEST="$(ls -t "${RESUME_DIR}"/*.json 2>/dev/null | tail -1)"

if [ -z "$OLDEST" ]; then
  exit 0
fi

# Move to processed immediately to prevent double-dispatch
BASENAME="$(basename "$OLDEST")"
mv "$OLDEST" "${PROCESSED_DIR}/${BASENAME}" 2>/dev/null || exit 0

# Read plan_file and resume_from_batch via python3 to handle paths safely
export CAST_RESUME_FILE="${PROCESSED_DIR}/${BASENAME}"

PLAN_FILE="$(python3 -c "
import json, os
f = os.environ.get('CAST_RESUME_FILE', '')
try:
    with open(f) as fh:
        d = json.load(fh)
    print(d.get('plan_file') or '')
except Exception:
    print('')
" 2>/dev/null || echo "")"

RESUME_FROM="$(python3 -c "
import json, os
f = os.environ.get('CAST_RESUME_FILE', '')
try:
    with open(f) as fh:
        d = json.load(fh)
    print(int(d.get('resume_from_batch', 1)))
except Exception:
    print('1')
" 2>/dev/null || echo "1")"

if [ -z "$PLAN_FILE" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] resume-watcher: no plan_file in ${BASENAME} — skipping" >> "$LOG_FILE" 2>/dev/null || true
  exit 0
fi

PREV_BATCH="$((RESUME_FROM - 1))"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] resume-watcher: resuming ${PLAN_FILE} from batch ${RESUME_FROM}" >> "$LOG_FILE" 2>/dev/null || true

claude -p "Resume orchestrator plan at ${PLAN_FILE}. Batches 1 through ${PREV_BATCH} are complete. Skip them and execute from Batch ${RESUME_FROM} to the end without asking for approval." \
  >> "$LOG_FILE" 2>&1 || true

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] resume-watcher: claude invocation finished" >> "$LOG_FILE" 2>/dev/null || true

exit 0
