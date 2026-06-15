#!/bin/bash
# cast-time-context-hook.sh — SessionStart hook
# Injects local date/time/timezone context into Claude's context window.
# Uses hookSpecificOutput to surface structured time context at session start.
# Exit 0 always — must never block the session.

if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

set -euo pipefail

_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

# --- Gather time data (all via date, no external deps) ---
LOCAL_DATE="$(date '+%Y-%m-%d')"
LOCAL_TIME="$(date '+%H:%M')"
TZ_ABBREV="$(date '+%Z')"
UTC_OFFSET="$(date '+%z')"          # e.g. -0500
HOUR_RAW="$(date '+%H')"            # always 2-digit with leading zero
HOUR=$((10#${HOUR_RAW}))            # strip leading zero for arithmetic (portable)
DAY_OF_WEEK="$(date '+%A')"         # e.g. Tuesday
DAY_NUM="$(date '+%u')"             # 1=Mon...7=Sun
EPOCH="$(date '+%s')"
ISO_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
FULL_DATE="$(date '+%A, %Y-%m-%d')" # e.g. Tuesday, 2026-05-05

# --- Weekend flag ---
if (( DAY_NUM >= 6 )); then
  DAY_TYPE="weekend"
else
  DAY_TYPE="weekday"
fi

# --- Semantic bucket ---
if   (( HOUR >= 0  && HOUR <= 4  )); then BUCKET="late-night"
elif (( HOUR >= 5  && HOUR <= 6  )); then BUCKET="early-morning"
elif (( HOUR >= 7  && HOUR <= 11 )); then BUCKET="morning"
elif (( HOUR == 12 ));               then BUCKET="midday"
elif (( HOUR >= 13 && HOUR <= 16 )); then BUCKET="afternoon"
elif (( HOUR >= 17 && HOUR <= 20 )); then BUCKET="evening"
else                                      BUCKET="night"
fi

# --- Format UTC offset as UTC+X / UTC-X ---
OFFSET_SIGN="${UTC_OFFSET:0:1}"
OFFSET_H="${UTC_OFFSET:1:2}"
OFFSET_M="${UTC_OFFSET:3:2}"
if [[ "$OFFSET_M" == "00" ]]; then
  UTC_LABEL="UTC${OFFSET_SIGN}${OFFSET_H#0}"
else
  UTC_LABEL="UTC${OFFSET_SIGN}${OFFSET_H#0}:${OFFSET_M}"
fi

# --- Export data vars for Python JSON build ---
export CAST_TC_FULL_DATE="$FULL_DATE"
export CAST_TC_LOCAL_TIME="$LOCAL_TIME"
export CAST_TC_TZ_ABBREV="$TZ_ABBREV"
export CAST_TC_UTC_LABEL="$UTC_LABEL"
export CAST_TC_DAY_TYPE="$DAY_TYPE"
export CAST_TC_BUCKET="$BUCKET"
export CAST_TC_ISO_UTC="$ISO_UTC"
export CAST_TC_EPOCH="$EPOCH"

# --- Emit hookSpecificOutput via json.dumps (correct newline encoding) ---
python3 -c '
import json, os
lines = [
    "## Session Time Context",
    "",
    "Date: "         + os.environ["CAST_TC_FULL_DATE"],
    "Time: "         + os.environ["CAST_TC_LOCAL_TIME"] + " " + os.environ["CAST_TC_TZ_ABBREV"],
    "Timezone: "     + os.environ["CAST_TC_TZ_ABBREV"] + " (" + os.environ["CAST_TC_UTC_LABEL"] + ")",
    "Day type: "     + os.environ["CAST_TC_DAY_TYPE"],
    "Time of day: "  + os.environ["CAST_TC_BUCKET"],
    "Session started: " + os.environ["CAST_TC_ISO_UTC"] + " (epoch: " + os.environ["CAST_TC_EPOCH"] + ")",
    "",
    "Note: This context is injected once at session start. Times shown are local to the machine running Claude Code.",
]
context_text = "\n".join(lines)
output = {
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": context_text
    }
}
print(json.dumps(output))
' || _log_error "python3 json build failed"

exit 0
