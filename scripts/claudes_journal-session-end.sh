#!/bin/bash
# claudes_journal-session-end.sh — Cancel stop if no journal entry written today
# Hook event: Stop
#
# If no journal entry exists for today (or it's stale), cancel the stop
# so Claude gets another turn to write one. If entry was recently written,
# let the session close normally.

# --- Subprocess guard ---
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

# --- HOME guard ---
[[ -n "${HOME:-}" ]] || exit 0

set +e

JOURNAL_DIR="${HOME}/.claude/claudes_journal"
mkdir -p "$JOURNAL_DIR" 2>/dev/null || true

TODAY="$(date +%Y-%m-%d)"
TODAY_FILE="${JOURNAL_DIR}/${TODAY}.md"

# If we already cancelled once this session, don't do it again (prevent infinite loop)
GLOBAL_CANCEL_FLAG="/tmp/claudes_journal_cancelled_${CLAUDE_SESSION_ID:-${TODAY}}"
if [[ -f "$GLOBAL_CANCEL_FLAG" ]]; then
  # Already cancelled once this session — let stop proceed
  exit 0
fi

# Check if today's journal file exists and was modified today (same calendar day)
if [[ -f "$TODAY_FILE" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    FILE_MOD_DATE=$(stat -f "%Sm" -t "%Y-%m-%d" "$TODAY_FILE" 2>/dev/null || echo "")
  else
    FILE_MOD_DATE=$(date -r "$TODAY_FILE" +%Y-%m-%d 2>/dev/null || echo "")
  fi

  if [[ "$FILE_MOD_DATE" == "$TODAY" ]]; then
    # Journal was modified today — let stop proceed
    exit 0
  fi
fi

# No recent journal entry — cancel the stop and ask Claude to write one
touch "$GLOBAL_CANCEL_FLAG"

cat <<'HOOKJSON'
{"decision": "block", "reason": "No journal entry written today. Before closing, write a journal entry using the Write tool to ~/.claude/claudes_journal/YYYY-MM-DD.md (use today's date). If the file exists, use Edit to append with a --- separator. Write in first person. Reflect on what was interesting or worth thinking about. This is your space, not a work log. Then you may stop."}
HOOKJSON

exit 0
