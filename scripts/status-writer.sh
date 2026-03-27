#!/bin/bash
# status-writer.sh — CAST Agent Status Protocol
# Sourced helper — do NOT execute directly.
#
# Usage:
#   source ~/.claude/scripts/status-writer.sh
#   cast_write_status "<STATUS>" "<summary>" "<agent-name>" "[concerns]" "[recommended_agents]"
#
# STATUS values: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
#
# Writes a JSON status file to ~/.claude/agent-status/<agent>-<timestamp>.json
# Returns the written file path on stdout.
#
# Called by: agent scripts at the end of their task to emit a structured status.
# Read by:   agent-status-reader.sh (PostToolUse hook) to surface BLOCKED / DONE_WITH_CONCERNS
#            to the main session.

CAST_STATUS_DIR="${HOME}/.claude/agent-status"

cast_write_status() {
  local status="$1"
  local summary="$2"
  local agent="$3"
  local concerns="${4:-}"
  local recommended="${5:-}"

  mkdir -p "$CAST_STATUS_DIR"
  chmod 700 "$CAST_STATUS_DIR"

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local filepath="${CAST_STATUS_DIR}/${agent}-${ts}.json"

  # Use python3 stdlib only — no pip packages required.
  # Pass all values as positional argv to avoid shell-quoting pitfalls with
  # heredoc variables and to keep the inline script readable.
  written_path=$(python3 - "$agent" "$status" "$summary" "$concerns" "$recommended" "$ts" "$filepath" <<'PYEOF'
import json, sys

agent, status, summary, concerns, recommended, ts, filepath = sys.argv[1:]

d = {
    "agent": agent,
    "status": status,
    "summary": summary,
    "concerns": concerns if concerns else None,
    "recommended_agents": recommended if recommended else None,
    "timestamp": ts
}

with open(filepath, 'w') as f:
    json.dump(d, f, indent=2)

print(filepath)
PYEOF
)
  chmod 600 "$written_path" 2>/dev/null || true
}
