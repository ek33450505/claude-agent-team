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

# Resolve repo scripts directory — portable, no hardcoded paths
CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-$(dirname "$(readlink -f "$0")")}"

# --- Weekly routing feedback analysis ---
# Runs cast-routing-feedback.sh if last report is >7 days old or missing.
# Runs in background to avoid blocking session close.
CAST_ROUTING_FEEDBACK="${HOME}/.claude/scripts/cast-routing-feedback.sh"
# Also check repo-local version
REPO_FEEDBACK="${CAST_SCRIPTS_DIR}/cast-routing-feedback.sh"
if [ -f "$REPO_FEEDBACK" ]; then
  CAST_ROUTING_FEEDBACK="$REPO_FEEDBACK"
fi
if [ -f "$CAST_ROUTING_FEEDBACK" ]; then
  if ! bash "$CAST_ROUTING_FEEDBACK" --check 2>/dev/null; then
    bash "$CAST_ROUTING_FEEDBACK" > /tmp/cast-routing-feedback-last.log 2>&1 &
  fi
fi

# --- Project board refresh ---
CAST_BOARD="${HOME}/.claude/scripts/cast-board.sh"
REPO_BOARD="${CAST_SCRIPTS_DIR}/cast-board.sh"
if [ -f "$REPO_BOARD" ]; then
  CAST_BOARD="$REPO_BOARD"
fi
if [ -f "$CAST_BOARD" ]; then
  bash "$CAST_BOARD" > /tmp/cast-board-last.log 2>&1 &
fi

# --- Agent memory auto-initialization ---
CAST_AGENT_MEM_INIT="${HOME}/.claude/scripts/cast-agent-memory-init.sh"
REPO_MEM_INIT="${CAST_SCRIPTS_DIR}/cast-agent-memory-init.sh"
if [ -f "$REPO_MEM_INIT" ]; then
  CAST_AGENT_MEM_INIT="$REPO_MEM_INIT"
fi
if [ -f "$CAST_AGENT_MEM_INIT" ]; then
  bash "$CAST_AGENT_MEM_INIT" > /tmp/cast-agent-memory-init-last.log 2>&1 &
fi

# --- Auto-escalation rule engine ---
# Detects recurring BLOCKED patterns and reviewer concerns; writes auto-rules to cast.db.
CAST_MEM_ESCALATION="${HOME}/.claude/scripts/cast-memory-escalation.sh"
REPO_MEM_ESCALATION="${CAST_SCRIPTS_DIR}/cast-memory-escalation.sh"
if [ -f "$REPO_MEM_ESCALATION" ]; then
  CAST_MEM_ESCALATION="$REPO_MEM_ESCALATION"
fi
if [ -f "$CAST_MEM_ESCALATION" ]; then
  bash "$CAST_MEM_ESCALATION" > /tmp/cast-memory-escalation-last.log 2>&1 &
fi

# --- Cleanup CAST temp files for this session ---
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
rm -f "/tmp/cast-depth-${PPID}.depth" 2>/dev/null || true
rm -f /tmp/cast-blocked-${SESSION_ID}*.count 2>/dev/null || true
rm -f "/tmp/cast-dispatch-${SESSION_ID}.log" 2>/dev/null || true
rm -f "/tmp/cast-session-start-${SESSION_ID}.epoch" 2>/dev/null || true

exit 0
