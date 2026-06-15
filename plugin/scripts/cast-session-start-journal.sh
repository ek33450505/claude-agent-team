#!/bin/bash
# cast-session-start-journal.sh — inject most recent dated journal entry at SessionStart

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# Expand vault path once
VAULT_PATH="$HOME/Documents/Claude"

# Find most recent .md file. Guard against `set -o pipefail`: when vault is
# missing, `find` exits 1 and the pipeline terminates the script before the
# JSON fallback runs. Skip find entirely when vault dir is absent, and add
# `|| true` belt-and-suspenders so an empty pipeline never fails.
LATEST_ENTRY=""
if [[ -d "$VAULT_PATH" ]]; then
  if stat --version >/dev/null 2>&1; then
    LATEST_ENTRY=$(find "$VAULT_PATH" -maxdepth 2 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
  else
    LATEST_ENTRY=$(find "$VAULT_PATH" -maxdepth 2 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f -exec stat -f "%m %N" {} + 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
  fi
fi

# If vault dir missing or no entries found, emit JSON with systemMessage
if [[ ! -d "$VAULT_PATH" ]] || [[ -z "$LATEST_ENTRY" ]] || [[ ! -f "$LATEST_ENTRY" ]]; then
  export VAULT_PATH
  python3 << 'PYEOF'
import json, os
vault_path = os.environ.get("VAULT_PATH", "~/Documents/Claude")
output = {
    "systemMessage": f"📓 journal | ⚠️ Vault directory {vault_path} not found or empty",
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ""
    }
}
print(json.dumps(output))
PYEOF
  exit 0
fi

# Extract filename
BASENAME=$(basename "$LATEST_ENTRY")
DATEONLY="${BASENAME%.md}"

# Convert YYYY-MM-DD to pretty format — try BSD date -j first, then GNU date -d, then Python
PRETTY_DATE=$(date -j -f "%Y-%m-%d" "$DATEONLY" +"%B %d, %Y" 2>/dev/null \
  || date -d "$DATEONLY" +"%B %d, %Y" 2>/dev/null \
  || python3 -c "from datetime import datetime; print(datetime.strptime('$DATEONLY', '%Y-%m-%d').strftime('%B %d, %Y'))" 2>/dev/null \
  || echo "")

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
lines = ["## Last Claude's Journal Entry (" + date + ")", "", excerpt, ""]
context_text = "\n".join(lines)
output = {
    "systemMessage": f"📓 journal | Latest entry from {date}",
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": context_text
    }
}
print(json.dumps(output))
PYEOF

exit 0
