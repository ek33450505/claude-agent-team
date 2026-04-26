#!/usr/bin/env bash
# cast-journal-session-end.sh — prompt for per-date journal note in Obsidian vault on session close
# Hook event: Stop
# Timeout: 5 seconds

# --- Subprocess guard ---
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

[[ -n "${HOME:-}" ]] || exit 0

set +e

VAULT_DIR="${HOME}/Documents/Claude"
TODAY="$(date +%Y-%m-%d)"
MONTH="$(date +%Y-%m)"
MONTH_DIR="${VAULT_DIR}/${MONTH}"
TODAY_NOTE="${MONTH_DIR}/${TODAY}.md"

mkdir -p "$MONTH_DIR" 2>/dev/null

# One-cancel-per-session guard
CANCEL_FLAG="/tmp/cast_journal_cancelled_${CLAUDE_SESSION_ID:-${TODAY}}"
if [[ -f "$CANCEL_FLAG" ]]; then exit 0; fi

# If today's note already exists with content, we're done
if [[ -s "$TODAY_NOTE" ]]; then
  exit 0
fi

# No entry today — cancel stop once and ask for a journal entry
touch "$CANCEL_FLAG"

cat <<HOOKJSON
{"decision": "block", "reason": "No journal entry written today. Before closing, create a per-date note at ~/Documents/Claude/${MONTH}/${TODAY}.md using the Write tool. Start with a '# <Month Day, Year>' heading and write in first person. This is your space, not a work log — note what was interesting, surprising, or worth carrying forward. Use [[wiki-links]] to connect to prior entries when relevant. Then you may stop."}
HOOKJSON

exit 0
