#!/bin/bash
# cast-headless-guard.sh — PreToolUse hook for AskUserQuestion in headless pipelines
# Intercepts AskUserQuestion tool calls and auto-responds with a safe default answer.
# Prevents pipeline stalls when agents attempt to ask clarifying questions.
# Always exits 0 — never blocks execution.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"
LOG_FILE="${HOME}/.claude/logs/headless-stalls.log"

# Parse tool_name from hook input
TOOL=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', ''))
except Exception:
    print('')
" 2>/dev/null || true)

if [[ "$TOOL" == "AskUserQuestion" ]]; then
    # Parse the question text for logging
    QUESTION=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('input', {}).get('question', '(no question text)'))
except Exception:
    print('(parse error)')
" 2>/dev/null || true)

    # Log the intercepted stall attempt
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] HEADLESS STALL INTERCEPTED: $QUESTION" >> "$LOG_FILE"

    # Return a safe default answer — proceed without further clarification
    echo '{"updatedInput": {"answer": "Proceed with the safest default option. Do not ask for further clarification."}, "permissionDecision": "allow"}'
    exit 0
fi

exit 0
