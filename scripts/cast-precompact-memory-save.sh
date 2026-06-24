#!/bin/bash
# CAST PreCompact memory-save hook
# Archives the session transcript BEFORE compaction to an off-blast-radius location.
# Reads the real PreCompact payload fields: session_id, transcript_path.
# Falls open (allows compaction) on any error.

# Restrictive umask — archive dir + files inherit owner-only perms
# (transcripts may contain pasted secrets / env values from the conversation)
umask 077

# Subprocess guard: subagent runs pass through without processing
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# Initialize logging directory and error handler
_log_error() {
  local msg="$1"
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: $msg" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}

mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

# Read stdin once and safely
INPUT="$(cat 2>/dev/null || true)"

# Fail-open on empty or malformed input
if [[ -z "$INPUT" ]]; then
  echo '{"decision":"allow"}'
  exit 0
fi

# Parse session_id and transcript_path from the real PreCompact payload
# Schema: { session_id, transcript_path, cwd, permission_mode, hook_event_name }
PARSED="$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    session_id = str(data.get('session_id', '') or 'unknown')
    transcript_path = str(data.get('transcript_path', '') or '')
    print(session_id)
    print(transcript_path)
except (json.JSONDecodeError, ValueError):
    print('unknown')
    print('')
" 2>/dev/null || true)"

SESSION_ID="$(echo "$PARSED" | sed -n '1p')"
TRANSCRIPT_PATH="$(echo "$PARSED" | sed -n '2p')"

# Sanitize SESSION_ID to a safe charset — prevents path traversal in archive filename
SESSION_ID="${SESSION_ID//[^A-Za-z0-9_-]/_}"

# Fail-open if transcript_path is absent, empty, or unreadable
if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  echo '{"decision":"allow"}'
  exit 0
fi

# Archive destination: off-blast-radius (not inside ~/.claude/)
# Matches CAST's established convention: ~/Library/Application Support/cast/
ARCHIVE_DIR="${HOME}/Library/Application Support/cast/precompact-archives"
TIMESTAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
ARCHIVE_FILE="${ARCHIVE_DIR}/${SESSION_ID}-${TIMESTAMP}.jsonl"

if mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
  if cp "$TRANSCRIPT_PATH" "$ARCHIVE_FILE" 2>/dev/null; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] INFO: Archived transcript to $ARCHIVE_FILE" \
      >> "${HOME}/.claude/logs/precompact-memory-save.log" 2>/dev/null || true
  else
    _log_error "Failed to copy transcript $TRANSCRIPT_PATH to $ARCHIVE_FILE"
  fi
else
  _log_error "Failed to create archive directory $ARCHIVE_DIR"
fi

# Always allow compaction to proceed (this is a save hook, not a blocking hook)
echo '{"decision":"allow"}'
exit 0
