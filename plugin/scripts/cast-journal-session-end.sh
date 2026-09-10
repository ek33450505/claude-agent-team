#!/usr/bin/env bash
# cast-journal-session-end.sh — prompt for per-date journal note in Obsidian vault on session close
# Hook event: Stop
# Timeout: 5 seconds

# --- Subprocess guard ---
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

[[ -n "${HOME:-}" ]] || exit 0

set +e

VAULT_DIR="${CAST_JOURNAL_VAULT:-$HOME/Documents/Claude}"
TODAY="$(date +%Y-%m-%d)"
YESTERDAY="$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)"
MONTH="$(date +%Y-%m)"
MONTH_DIR="${VAULT_DIR}/${MONTH}"
TODAY_NOTE="${MONTH_DIR}/${TODAY}.md"
SCRATCH_FILE="${VAULT_DIR}/.scratch/${TODAY}.md"
# 10# forces base 10: `date +%H` zero-pads, and bash reads a leading zero as
# octal, so a bare "08"/"09" comparison errors with "value too great for base".
CURRENT_HOUR="$((10#$(date +%H)))"

mkdir -p "$MONTH_DIR" 2>/dev/null

# Configurable tmp base — allows tests to redirect flag paths via TMP env var
_TMP_BASE="${TMP:-${TMPDIR:-/tmp}}"
# Resolve symlinks for macOS compatibility (e.g., /tmp → /private/tmp)
_TMPDIR_REAL="$(realpath "$_TMP_BASE" 2>/dev/null || echo "$_TMP_BASE")"

# Cleanup cancel flags older than 1 day
find "$_TMPDIR_REAL" -maxdepth 1 -name "cast_journal_cancelled_*" -mtime +1 \
  -exec rm -f {} \; 2>/dev/null || true

# Cleanup wrap flags older than 1 day
find "$_TMPDIR_REAL" -maxdepth 1 -name "cast_journal_wrap_*" -mtime +1 \
  -exec rm -f {} \; 2>/dev/null || true

# Wrap-flag check: if user explicitly signaled session end, skip time/entry guards
WRAP_FLAG="${_TMP_BASE}/cast_journal_wrap_${TODAY}"
SKIP_GUARDS=0
[[ -f "$WRAP_FLAG" ]] && SKIP_GUARDS=1

# Time-of-day guard: if before 15:00 and not explicitly wrapping, exit
if [[ "$SKIP_GUARDS" -eq 0 && "$CURRENT_HOUR" -lt 15 ]]; then
  exit 0
fi

# Per-session marker — tracks whether we have already prompted this session
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"
SESSION_MARKER="${_TMP_BASE}/cast_journal_session_${SESSION_ID}"
CANCEL_FLAG="${_TMP_BASE}/cast_journal_cancelled_$(date +%Y-%m-%d)"

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
  if [[ "$CURRENT_HOUR" -lt 18 ]]; then
    # Before 18:00 → honor cancel flag
    exit 0
  fi
  # No entry + hour >= 18 → clear cancel flag and fall through to re-prompt
  rm -f "$CANCEL_FLAG" 2>/dev/null || true
fi

# Mark this session as having been prompted
touch "$SESSION_MARKER" 2>/dev/null || true

# If today's note already exists, check if it's substantive
if [[ -s "$TODAY_NOTE" ]]; then
  # Count non-blank lines in today's entry
  ENTRY_LINES=$(grep -c '[^[:space:]]' "$TODAY_NOTE" 2>/dev/null || echo 0)
  # If entry is substantial (>= 25 lines), we're done
  if [[ "$ENTRY_LINES" -ge 25 ]]; then
    exit 0
  fi
  # Stub entry detected: if past 18:00, clear cancel flag and fall through to re-prompt
  if [[ "$CURRENT_HOUR" -ge 18 ]]; then
    rm -f "$CANCEL_FLAG" 2>/dev/null || true
    # Will re-prompt with modified message below
  else
    # Before 18:00 and stub entry: don't prompt yet
    exit 0
  fi
fi

# No entry today — set cancel flag and ask for a journal entry
touch "$CANCEL_FLAG" 2>/dev/null || true

# Scratchpad distillation check (Phase 2)
SCRATCH_ADDENDUM=""
if [[ -f "$SCRATCH_FILE" ]] && [[ -s "$SCRATCH_FILE" ]]; then
  SCRATCH_ADDENDUM="\n\nYou have scratchpad notes from this session at ${SCRATCH_FILE}. Read them with the Read tool, distill key insights into today's journal entry, then you may stop."
fi

# Build prompt message based on whether this is a new entry or deepening a stub
if [[ -s "$TODAY_NOTE" ]]; then
  PROMPT_MESSAGE="Today's entry is brief. Before closing, add more if there's more to say.\n\n---\n**Prev:** [[${YESTERDAY}]]\n\nWrap recurring concepts as [[wiki-links]] (e.g., [[CAST]], [[Engram]], [[Managed Agents]]) so they form topic hubs in the graph.${SCRATCH_ADDENDUM}\nThen you may stop."
else
  PROMPT_MESSAGE="No journal entry written today. Before closing, create ~/Documents/Claude/${MONTH}/${TODAY}.md using the Write tool.\n\nSuggested starter:\n# <Month Day, Year>\n\n<your reflection — first person, what was interesting/surprising/worth carrying forward>\n\n---\n**Prev:** [[${YESTERDAY}]]\n\nWrap recurring concepts as [[wiki-links]] (e.g., [[CAST]], [[Engram]], [[Managed Agents]]) so they form topic hubs in the graph.${SCRATCH_ADDENDUM}\nThen you may stop."
fi

export CAST_PROMPT_MESSAGE="$PROMPT_MESSAGE"
python3 <<'PYEOF'
import json, os
msg = os.environ.get("CAST_PROMPT_MESSAGE", "")
print(json.dumps({"decision": "block", "reason": msg}))
PYEOF

# Clean up wrap flag if it was set
rm -f "$WRAP_FLAG" 2>/dev/null || true

exit 0
