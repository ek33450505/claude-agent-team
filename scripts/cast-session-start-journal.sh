#!/bin/bash
# cast-session-start-journal.sh — inject most recent dated journal entry at SessionStart

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# Find most recent .md file matching YYYY-MM-DD pattern in dated subdirectories
LATEST_ENTRY=$(find ~/Documents/Claude -maxdepth 2 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f -exec stat -f "%m %N" {} + 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -z "$LATEST_ENTRY" ]] || [[ ! -f "$LATEST_ENTRY" ]]; then
  exit 0
fi

# Extract filename
BASENAME=$(basename "$LATEST_ENTRY")
DATEONLY="${BASENAME%.md}"

# Convert YYYY-MM-DD to pretty format via date(1)
PRETTY_DATE=$(date -j -f "%Y-%m-%d" "$DATEONLY" +"%B %d, %Y" 2>/dev/null || echo "")

if [[ -z "$PRETTY_DATE" ]]; then
  exit 0
fi

# Read excerpt (first 50 lines or up to separator)
EXCERPT=$(head -50 "$LATEST_ENTRY" | sed '/^---$/q')

# Emit JSON with safe env-var passing to avoid shell expansion into Python literals
export CAST_JOURNAL_DATE="$PRETTY_DATE"
export CAST_JOURNAL_EXCERPT="$EXCERPT"

python3 << 'PYEOF'
import json, os
date = os.environ.get("CAST_JOURNAL_DATE", "")
excerpt = os.environ.get("CAST_JOURNAL_EXCERPT", "").rstrip()
# Build context with proper newline escaping for JSON
lines = ["## Last Claude's Journal Entry (" + date + ")", "", excerpt, "", "---"]
context_text = "\n".join(lines)
output = {
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": context_text
    }
}
print(json.dumps(output))
PYEOF

exit 0
