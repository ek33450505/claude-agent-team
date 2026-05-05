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
YESTERDAY="$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)"
MONTH="$(date +%Y-%m)"
MONTH_DIR="${VAULT_DIR}/${MONTH}"
TODAY_NOTE="${MONTH_DIR}/${TODAY}.md"

mkdir -p "$MONTH_DIR" 2>/dev/null

# Cleanup cancel flags older than 1 day (resolve /tmp symlink for macOS compatibility)
_TMPDIR_REAL="$(realpath /tmp 2>/dev/null || echo /tmp)"
find "$_TMPDIR_REAL" -maxdepth 1 -name "cast_journal_cancelled_*" -mtime +1 \
  -exec rm -f {} \; 2>/dev/null || true

# Per-session marker — tracks whether we have already prompted this session
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"
SESSION_MARKER="/tmp/cast_journal_session_${SESSION_ID}"
CANCEL_FLAG="/tmp/cast_journal_cancelled_$(date +%Y-%m-%d)"

if [[ -f "$CANCEL_FLAG" ]]; then
  # Second cancel same session: session marker present → already prompted once, always honor
  if [[ -f "$SESSION_MARKER" ]]; then
    exit 0
  fi
  # First call this session with cancel flag set — apply re-prompt logic
  if [[ -s "$TODAY_NOTE" ]]; then
    # Entry already exists → honor cancel flag
    exit 0
  fi
  CURRENT_HOUR="$(date +%H)"
  if [[ "$CURRENT_HOUR" -lt 18 ]]; then
    # Before 18:00 → honor cancel flag
    exit 0
  fi
  # No entry + hour >= 18 → clear cancel flag and fall through to re-prompt
  rm -f "$CANCEL_FLAG" 2>/dev/null || true
fi

# Mark this session as having been prompted
touch "$SESSION_MARKER" 2>/dev/null || true

# If today's note already exists with content, we're done
if [[ -s "$TODAY_NOTE" ]]; then
  exit 0
fi

# No entry today — set cancel flag and ask for a journal entry
touch "$CANCEL_FLAG" 2>/dev/null || true

cat <<HOOKJSON
{"decision": "block", "reason": "No journal entry written today. Before closing, create ~/Documents/Claude/${MONTH}/${TODAY}.md using the Write tool.\n\nSuggested starter:\n# <Month Day, Year>\n\n<your reflection — first person, what was interesting/surprising/worth carrying forward>\n\n---\n**Prev:** [[${YESTERDAY}]]\n\nWrap recurring concepts as [[wiki-links]] (e.g., [[CAST]], [[Engram]], [[Managed Agents]]) so they form topic hubs in the graph. Then you may stop."}
HOOKJSON

exit 0
