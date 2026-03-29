#!/bin/bash
# cast-security-guard.sh — PreToolUse security advisory hook
# Fires on Write, Edit, Bash tools when sensitive file paths or commands are detected.
# Always exits 0 (advisory only — never hard-blocks).

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# Touch marker for dashboard hook health
mkdir -p "${HOME}/.claude/cast/hook-last-fired"
touch "${HOME}/.claude/cast/hook-last-fired/cast-security-guard.timestamp"

INPUT="$(cat)"

TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_name', ''))
" 2>/dev/null || echo "")

# Only fire for Write, Edit, Bash
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

# Extract relevant fields
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")

COMMAND=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('command', ''))
" 2>/dev/null || echo "")

MATCHED=false
REASON=""

# --- File path checks (Write / Edit) ---
if [[ -n "$FILE_PATH" ]]; then
  # Skip test files
  if [[ "$FILE_PATH" =~ \.(test|spec)\. ]] || [[ "$FILE_PATH" =~ __tests__ ]]; then
    exit 0
  fi

  # Sensitive path patterns
  if [[ "$FILE_PATH" =~ \.env($|\.) ]] || \
     [[ "$FILE_PATH" =~ \.env\. ]] || \
     [[ "$FILE_PATH" =~ (^|/)credentials ]] || \
     [[ "$FILE_PATH" =~ (^|/)secret ]] || \
     [[ "$FILE_PATH" =~ (^|/)auth\. ]] || \
     [[ "$FILE_PATH" =~ middleware/auth ]] || \
     [[ "$FILE_PATH" =~ api[-_]key ]] || \
     [[ "$FILE_PATH" =~ [-_]token\. ]] || \
     [[ "$FILE_PATH" =~ password ]]; then
    MATCHED=true
    REASON="Sensitive file path: ${FILE_PATH}"
  fi
fi

# --- Command checks (Bash) ---
if [[ -n "$COMMAND" ]] && ! $MATCHED; then
  if echo "$COMMAND" | grep -qE 'curl.+(-u |--user |Authorization)' || \
     echo "$COMMAND" | grep -qE '^ssh .+@' || \
     echo "$COMMAND" | grep -qE '^scp .+:'; then
    MATCHED=true
    REASON="Sensitive command detected"
  fi
fi

if $MATCHED; then
  CAST_REASON="$REASON" python3 -c "
import json, os
reason = os.environ.get('CAST_REASON', '')
msg = '[CAST-REVIEW-SECURITY] Sensitive operation detected: {}. Consider dispatching the \`security\` agent (sonnet) to review this change before committing. Run: /secure'.format(reason)
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'additionalContext': msg}}))
"
fi

exit 0
