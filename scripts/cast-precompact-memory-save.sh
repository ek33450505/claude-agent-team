#!/bin/bash
# CAST PreCompact memory-save hook
# Saves a snapshot of the conversation summary before compaction
# Adapted from Hindsight memory-save pattern

# Restrictive umask — snapshot dir + files inherit owner-only perms
# (session summaries may contain pasted secrets / env values from the conversation)
umask 077

# Subprocess guard: allow subagent runs to pass through without processing
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# Initialize logging directory and error handler
_log_error() {
  local msg="$1"
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: $msg" >> ~/.claude/logs/hook-errors.log 2>/dev/null || true
}

mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

# Read stdin once and safely
INPUT="$(cat 2>/dev/null || true)"

# Extract summary field from PreCompact JSON payload
SUMMARY=""
if [[ -n "$INPUT" ]]; then
  SUMMARY=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # PreCompact payload typically has 'summary' or 'context' field
    summary = data.get('summary', data.get('context', ''))
    if summary:
        print(summary)
except (json.JSONDecodeError, ValueError):
    pass
" 2>/dev/null || echo "")
fi

# Save snapshot if we have content
if [[ -n "$SUMMARY" ]]; then
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  SNAPSHOT_DIR="${HOME}/.claude/agent-memory-local/session-snapshots"

  if mkdir -p "$SNAPSHOT_DIR" 2>/dev/null; then
    SNAPSHOT_FILE="${SNAPSHOT_DIR}/${TIMESTAMP}.md"
    {
      echo "# Session Snapshot: $TIMESTAMP"
      echo ""
      echo "$SUMMARY"
    } > "$SNAPSHOT_FILE" 2>/dev/null || {
      _log_error "Failed to write snapshot to $SNAPSHOT_FILE"
    }

    # Log success
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] INFO: Saved memory snapshot to $SNAPSHOT_FILE" >> ~/.claude/logs/precompact-memory-save.log 2>/dev/null || true
  else
    _log_error "Failed to create snapshot directory $SNAPSHOT_DIR"
  fi
fi

# Always allow compaction to proceed (this is a save hook, not a blocking hook)
echo '{"decision":"allow"}'
exit 0
