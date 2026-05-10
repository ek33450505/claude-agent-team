#!/bin/bash
# cast-no-fake-success-guard.sh — PreToolUse warn-only hook for fake-success detection
#
# Warns when try/catch blocks return sample/fake/mock data, which can mask integration
# failures and ship broken code silently. Exit codes: 0 = allow (always, warn-only hook).
# Suppression escape hatch: add `fake-success-ok` in any comment style.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

LOG_FILE="${HOME}/.claude/logs/no-fake-success-guard.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Read stdin once, pass via env var to Python parser
INPUT="$(cat 2>/dev/null || true)"
export CAST_NFG_INPUT="$INPUT"

# Parse JSON fields using Python
TOOL="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_NFG_INPUT','{}') or '{}'); print(d.get('tool_name',''))" 2>/dev/null || echo "")"
FILE_PATH="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_NFG_INPUT','{}') or '{}'); ti=d.get('tool_input',{}) or {}; print(ti.get('file_path', ''))" 2>/dev/null || echo "")"
CONTENT="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_NFG_INPUT','{}') or '{}'); ti=d.get('tool_input',{}) or {}; print(ti.get('content', ti.get('new_string','')))" 2>/dev/null || echo "")"

# Only trigger on Write/Edit tools
if [[ ! "$TOOL" =~ ^(Write|Edit)$ ]]; then
  exit 0
fi

# Skip test files and non-code extensions
if [[ "$FILE_PATH" =~ (^|/)tests/ || "$FILE_PATH" =~ \.(test|spec)\. || "$FILE_PATH" =~ (^|/)fixtures/ ]]; then
  exit 0
fi

# Only check specific language extensions
if ! [[ "$FILE_PATH" =~ \.(py|js|jsx|ts|tsx|mjs|cjs)$ ]]; then
  exit 0
fi

# Escape hatch: if content contains fake-success-ok (any comment style), skip silently
if echo "$CONTENT" | grep -qi "fake-success-ok"; then
  exit 0
fi

# Normalize multi-line content for matching: replace newlines with spaces
NORMALIZED_CONTENT=$(echo "$CONTENT" | tr '\n' ' ')

# Match fake-success patterns (case-insensitive)
# Python: try...except...return (sample|fake|mock|placeholder|dummy)
# JS/TS: try...catch...return [{sample|fake|mock}
MATCHED=0
PATTERN=""

if [[ "$FILE_PATH" =~ \.py$ ]]; then
  if echo "$NORMALIZED_CONTENT" | grep -qiE "try.*(except|finally).*return.*(sample|fake|mock|placeholder|dummy)"; then
    MATCHED=1
    PATTERN="Python try/except → return sample/fake/mock data"
  fi
elif [[ "$FILE_PATH" =~ \.(js|jsx|ts|tsx|mjs|cjs)$ ]]; then
  if echo "$NORMALIZED_CONTENT" | grep -qiE "try.*catch.*return.*[\[\{].*(sample|fake|mock)"; then
    MATCHED=1
    PATTERN="JS/TS try/catch → return sample/fake/mock data"
  fi
fi

if [ "$MATCHED" -eq 0 ]; then
  exit 0
fi

# Log the warn event
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "[$TIMESTAMP] WARN: $PATTERN in $FILE_PATH"
} >> "$LOG_FILE" 2>/dev/null || true

# Log to cast.db quality_gates table (non-fatal if DB unavailable)
DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"
if [ -f "$DB_PATH" ]; then
  GATE_ID=$(uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || echo "")
  if [ -n "$GATE_ID" ]; then
    GATE_SUMMARY="fake-success warn: $PATTERN in $FILE_PATH"
    # Escape single quotes for SQL (replace ' with '')
    GATE_SUMMARY_SQL="${GATE_SUMMARY//\'/\'\'}"
    SESSION_ID_SQL="${CAST_SESSION_ID:-unknown}"
    SESSION_ID_SQL="${SESSION_ID_SQL//\'/\'\'}"
    sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO quality_gates (id, session_id, agent_name, timestamp, status_line, contract_passed) VALUES ('$GATE_ID', '$SESSION_ID_SQL', 'cast-no-fake-success-guard', '$TIMESTAMP', '$GATE_SUMMARY_SQL', 0);" 2>/dev/null || true
  fi
fi

# Emit hookSpecificOutput warning (warn-only, exit 0 always)
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[CAST FAKE-SUCCESS WARN] $FILE_PATH: try/except|catch returns sample/mock data — verify this is intentional, not silent failure masking. Skip with /* fake-success-ok */ comment if intentional."}}
EOF

exit 0
