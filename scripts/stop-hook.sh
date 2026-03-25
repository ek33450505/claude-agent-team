#!/bin/bash
# stop-hook.sh — CAST Stop hook for chain-reporter auto-dispatch
# Hook event: Stop
#
# Purpose:
#   When a session ends, check if multi-batch orchestrator work was done this session.
#   If yes, inject a [CAST-CHAIN] directive prompting chain-reporter dispatch.
#
# Detection heuristics:
#   1. ~/.claude/cast/orchestrator-checkpoint.log exists (orchestrator wrote checkpoints)
#   2. OR event files in ~/.claude/cast/events/ were written in the last 30 minutes

set -euo pipefail

CAST_DIR="${HOME}/.claude/cast"
CHECKPOINT_FILE="${CAST_DIR}/orchestrator-checkpoint.log"
EVENTS_DIR="${CAST_DIR}/events"
SESSION_ID="${CLAUDE_SESSION_ID:-default}"

MULTI_BATCH_DETECTED=0

# Heuristic 1: checkpoint log exists and has at least one BATCH COMPLETE entry
if [ -f "$CHECKPOINT_FILE" ]; then
  if grep -q 'BATCH.*COMPLETE' "$CHECKPOINT_FILE" 2>/dev/null; then
    MULTI_BATCH_DETECTED=1
  fi
fi

# Heuristic 2: recent event files in the last 30 minutes (only check if not already detected)
if [ "$MULTI_BATCH_DETECTED" -eq 0 ] && [ -d "$EVENTS_DIR" ]; then
  RECENT_COUNT=$(find "$EVENTS_DIR" -name "*.json" -mmin -30 2>/dev/null | wc -l | tr -d ' ')
  if [ "${RECENT_COUNT:-0}" -gt 2 ]; then
    MULTI_BATCH_DETECTED=1
  fi
fi

if [ "$MULTI_BATCH_DETECTED" -eq 0 ]; then
  exit 0
fi

# Locate plan file path from checkpoint log if available
PLAN_FILE=""
if [ -f "$CHECKPOINT_FILE" ]; then
  # Attempt to extract a plan file path from checkpoint contents
  PLAN_FILE=$(grep -oE '~/.claude/plans/[^[:space:]]+\.md' "$CHECKPOINT_FILE" 2>/dev/null | tail -1 || echo "")
fi

PLAN_CONTEXT=""
if [ -n "$PLAN_FILE" ]; then
  PLAN_CONTEXT=" Pass the plan file path: ${PLAN_FILE}."
fi

python3 -c "
import json
msg = (
    '[CAST-CHAIN] Multi-agent chain session complete. '
    'Dispatch \`chain-reporter\` (haiku) to summarize what each agent did, key findings, and commits.$PLAN_CONTEXT'
)
output = {
    'hookSpecificOutput': {
        'hookEventName': 'Stop',
        'additionalContext': msg
    }
}
print(json.dumps(output))
" 2>/dev/null || true

exit 0
