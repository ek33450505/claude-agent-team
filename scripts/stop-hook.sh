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
#   2. OR orchestrator-checkpoint.log was modified in the last 30 minutes

set -euo pipefail

# 3a: Only fire in the main session — not inside subagents
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

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

# Heuristic 2: checkpoint log modified in the last 30 minutes — session-scoped signal.
# The orchestrator clears the checkpoint at session end, so a recent mtime means this
# session. This replaces the find-based event-file count which was not session-scoped.
if [ "$MULTI_BATCH_DETECTED" -eq 0 ] && [ -f "$CHECKPOINT_FILE" ]; then
  CHECKPOINT_AGE=$(( $(date +%s) - $(stat -f '%m' "$CHECKPOINT_FILE" 2>/dev/null || echo 0) ))
  if [ "$CHECKPOINT_AGE" -lt 1800 ]; then
    MULTI_BATCH_DETECTED=1
  fi
fi

if [ "$MULTI_BATCH_DETECTED" -eq 0 ]; then
  exit 0
fi

# Locate plan file path from checkpoint log if available.
# 3b: Use $HOME expansion — checkpoint logs write absolute paths (/Users/…/.claude/plans/…).
# The tilde pattern '~/.claude/plans/…' never matches absolute paths.
PLAN_FILE=""
if [ -f "$CHECKPOINT_FILE" ]; then
  PLAN_FILE=$(grep -oE "${HOME}/.claude/plans/[^[:space:]]+\\.md" "$CHECKPOINT_FILE" 2>/dev/null | tail -1 || echo "")
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

# --- Cleanup CAST temp files for this session ---
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
rm -f "/tmp/cast-depth-${PPID}.depth" 2>/dev/null || true
rm -f /tmp/cast-blocked-${SESSION_ID}*.count 2>/dev/null || true
rm -f "/tmp/cast-dispatch-${SESSION_ID}.log" 2>/dev/null || true
rm -f "/tmp/cast-session-start-${SESSION_ID}.epoch" 2>/dev/null || true

exit 0
