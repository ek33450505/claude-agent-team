#!/bin/bash
# post-tool-hook.sh — Combined PostToolUse hook for Write|Edit|Agent|Bash operations
# 1. Injects [CAST-CHAIN] / [CAST-REVIEW] directive differentiated by session context + file type
# 2. Detects Agent Dispatch Manifests in .md plan files (all sessions, including subagents)
# 3. Logs agent dispatches to routing-log.jsonl + writes chain_dispatched status files
# 4. Emits [CAST-DEBUG] directive for non-zero Bash exits (main session only)

set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

# D5: Touch marker file for hook health tracking
mkdir -p ~/.claude/cast/hook-last-fired && touch ~/.claude/cast/hook-last-fired/PostToolUse.timestamp

INPUT="$(cat)"

# Delegate all logic to cast-post-tool.py — reads stdin JSON once, handles all parts
python3 "$(dirname "$0")/cast-post-tool.py" <<< "$INPUT" || true

exit 0
