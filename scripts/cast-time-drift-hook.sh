#!/bin/bash
# cast-time-drift-hook.sh — UserPromptSubmit hook
# Re-injects time context when the SessionStart snapshot has gone stale.
#
# cast-time-context-hook.sh runs once, at SessionStart. A session that opens at
# 18:08 and is still running at 01:00 carries "Wednesday / evening" in context
# for hours after both stopped being true — and anything that derives a date
# from that context (a journal filename, a dated note, a "convert relative dates
# to absolute" memory write) silently records the wrong day.
#
# This hook stays silent on the overwhelming majority of prompts. It emits only
# when the local DATE has rolled over, or when enough time has passed that the
# time-of-day bucket is no longer trustworthy.
#
# Exit 0 always — must never block a prompt.

if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

set -euo pipefail

_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

# Re-inject after this many seconds even when the date has not changed.
# 3h is roughly the width of the semantic buckets the SessionStart hook emits.
DRIFT_SECONDS="${CAST_TIME_DRIFT_SECONDS:-10800}"

STATE_DIR="${CAST_TIME_STATE_DIR:-${HOME}/.claude/.cast-time}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Read the hook payload for a session id. Never fail on empty/absent stdin.
INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("session_id", "") or "default")
except Exception:
    print("default")
' 2>/dev/null || echo "default")"
# Keep the id filesystem-safe without depending on its format.
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)"
# `tr` preserves ".", so "." and ".." survive sanitisation and would resolve to
# a directory rather than a state file. Reject any all-dots id outright.
[[ "$SESSION_ID" =~ ^\.+$ ]] && SESSION_ID="default"
[[ -z "$SESSION_ID" ]] && SESSION_ID="default"

STATE_FILE="${STATE_DIR}/${SESSION_ID}"
NOW_EPOCH="$(date '+%s')"
NOW_DATE="$(date '+%Y-%m-%d')"

# Prune state files older than 7 days so a long-lived install does not accrete.
find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || true

# First prompt of a session: SessionStart already injected. Seed and stay quiet.
if [[ ! -f "$STATE_FILE" ]]; then
  printf '%s|%s|%s\n' "$NOW_EPOCH" "$NOW_EPOCH" "$NOW_DATE" > "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

IFS='|' read -r START_EPOCH LAST_EPOCH LAST_DATE < "$STATE_FILE" 2>/dev/null || true
# A truncated or hand-edited state file must not wedge the hook.
if [[ ! "$START_EPOCH" =~ ^[0-9]+$ || ! "$LAST_EPOCH" =~ ^[0-9]+$ || -z "$LAST_DATE" ]]; then
  printf '%s|%s|%s\n' "$NOW_EPOCH" "$NOW_EPOCH" "$NOW_DATE" > "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

ELAPSED_SINCE_INJECT=$(( NOW_EPOCH - LAST_EPOCH ))

REASON=""
if [[ "$NOW_DATE" != "$LAST_DATE" ]]; then
  REASON="date-rollover"
elif (( ELAPSED_SINCE_INJECT >= DRIFT_SECONDS )); then
  REASON="elapsed"
else
  exit 0
fi

printf '%s|%s|%s\n' "$START_EPOCH" "$NOW_EPOCH" "$NOW_DATE" > "$STATE_FILE" 2>/dev/null || true

export CAST_TD_REASON="$REASON"
export CAST_TD_PREV_DATE="$LAST_DATE"
export CAST_TD_START_EPOCH="$START_EPOCH"
export CAST_TD_NOW_EPOCH="$NOW_EPOCH"

python3 -c '
import json, os
from datetime import datetime

reason      = os.environ["CAST_TD_REASON"]
prev_date   = os.environ["CAST_TD_PREV_DATE"]
start_epoch = int(os.environ["CAST_TD_START_EPOCH"])
now_epoch   = int(os.environ["CAST_TD_NOW_EPOCH"])

now = datetime.fromtimestamp(now_epoch).astimezone()

def bucket(h):
    if   0 <= h <= 4:  return "late-night"
    elif 5 <= h <= 6:  return "early-morning"
    elif 7 <= h <= 11: return "morning"
    elif h == 12:      return "midday"
    elif 13 <= h <= 16: return "afternoon"
    elif 17 <= h <= 20: return "evening"
    return "night"

total = max(0, now_epoch - start_epoch)
h, m = divmod(total // 60, 60)
elapsed = f"{h}h {m:02d}m" if h else f"{m}m"

lines = ["## Session Time Context — updated"]
if reason == "date-rollover":
    today_str = now.strftime("%Y-%m-%d")
    lines += [
        "",
        f"The local date changed to {today_str} during this session "
        f"(it was {prev_date} at the last update).",
        "Anything dated from the earlier context in this session used the wrong day.",
    ]
else:
    lines += ["", "The session-start time context has gone stale. Current values:"]

lines += [
    "",
    "Date: "        + now.strftime("%A, %Y-%m-%d"),
    "Time: "        + now.strftime("%H:%M %Z"),
    "Day type: "    + ("weekend" if now.isoweekday() >= 6 else "weekday"),
    "Time of day: " + bucket(now.hour),
    "Elapsed (since first prompt): " + elapsed,
    "",
    "This supersedes the time context injected at session start.",
]

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": "\n".join(lines),
    }
}))
' || _log_error "python3 json build failed"

exit 0
