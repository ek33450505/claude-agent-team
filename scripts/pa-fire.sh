#!/usr/bin/env bash
# pa-fire.sh — Headless agent launcher for JARVIS PA agents
# Usage: pa-fire.sh <agent-name>
# Environment: JARVIS_SPEAK=1 to enable TTS output via macOS say
set -euo pipefail

AGENT="${1:?Usage: pa-fire.sh <agent-name>}"
LOG_DIR="${HOME}/.claude/logs"
VAULT_DIR="/Users/edkubiak/JARVIS"
mkdir -p "$LOG_DIR"

# Load API key from keychain if available (optional — OAuth auth works without it)
ANTHROPIC_API_KEY=$(security find-generic-password -s "ANTHROPIC_API_KEY" -w 2>/dev/null || true)
if [[ -n "$ANTHROPIC_API_KEY" ]]; then
  export ANTHROPIC_API_KEY
else
  echo "[INFO] No API key in keychain — using OAuth auth" >> "$LOG_DIR/${AGENT}.log"
fi

# TTS option — set JARVIS_SPEAK=1 in environment or shell profile to enable
JARVIS_SPEAK="${JARVIS_SPEAK:-0}"

# Strip markdown formatting for TTS
strip_md() {
  local file="$1"
  sed 's/^#\+[[:space:]]*//; s/\*\*//g; s/\*//g; s/`[^`]*`//g; s/\[[^]]*\]([^)]*\)//g; s/^[-*][[:space:]]*//' "$file"
}

# Speak output file if JARVIS_SPEAK=1
speak_output() {
  local file="$1"
  if [[ "${JARVIS_SPEAK}" == "1" ]] && [[ -f "$file" ]]; then
    strip_md "$file" | say -v Zoe
  fi
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Firing ${AGENT}" >> "$LOG_DIR/${AGENT}.log"

OUTPUT_FILE=$(claude -p "Run the ${AGENT} agent. Execute its full workflow as defined in ~/.claude/agents/core/${AGENT}.md. Report the primary output file path as the last line of your response." \
  --output-format json \
  2>> "$LOG_DIR/${AGENT}-err.log" \
  | python3 -c "
import sys, json
try:
    result = json.load(sys.stdin)
    print(result.get('result', 'No result'))
except:
    print(sys.stdin.read())
" | tee -a "$LOG_DIR/${AGENT}.log" | tail -1)

# Speak output if TTS enabled and agent produced a file
if [[ -f "$OUTPUT_FILE" ]]; then
  speak_output "$OUTPUT_FILE"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done ${AGENT}" >> "$LOG_DIR/${AGENT}.log"
