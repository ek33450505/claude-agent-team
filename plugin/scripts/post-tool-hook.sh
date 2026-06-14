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

INPUT="$(cat)"

# Delegate all logic to cast-post-tool.py — reads stdin JSON once, handles all parts
HOOK_OUTPUT="$(python3 "$(dirname "$0")/cast-post-tool.py" <<< "$INPUT" 2>/dev/null)" || true

# Guard: if output exceeds 50K, write to disk and emit path instead
MAX_BYTES=51200
OUTPUT_LEN="${#HOOK_OUTPUT}"
if [ "$OUTPUT_LEN" -gt "$MAX_BYTES" ]; then
  OVERFLOW_FILE="${HOME}/.claude/logs/hook-overflow-$(date -u +%Y%m%dT%H%M%SZ).txt"
  mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
  # --engine regex: regex covers all credential/secret patterns; spaCy NER is lower-stakes
  # for an overflow log field — avoids 0.5–3s Presidio startup cost on this hot path.
  REDACTED=$(printf '%s' "$HOOK_OUTPUT" | python3 "${HOME}/.claude/scripts/cast-redact.py" --engine regex 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("redacted_text",""))' 2>/dev/null)
  if [ -n "$REDACTED" ]; then
    printf '%s' "$REDACTED" > "$OVERFLOW_FILE" 2>/dev/null || true
    REDACTED_OK="true"
  else
    # fail-closed: don't write raw output if redaction failed
    printf '[REDACTION_FAILED — original %d bytes discarded for safety]' "$OUTPUT_LEN" > "$OVERFLOW_FILE" 2>/dev/null || true
    REDACTED_OK="false"
  fi
  HOOK_OUTPUT="{\"overflow\": true, \"path\": \"$OVERFLOW_FILE\", \"original_bytes\": $OUTPUT_LEN, \"redacted\": $REDACTED_OK}"
fi

# Only emit if there is actual content — a bare newline from an empty
# HOOK_OUTPUT would be treated as non-JSON by the CLI and crash it.
if [ -n "$HOOK_OUTPUT" ] && [ "$(echo "$HOOK_OUTPUT" | tr -d ' \t\n')" != "" ]; then
  printf '%s\n' "$HOOK_OUTPUT"
fi

exit 0
