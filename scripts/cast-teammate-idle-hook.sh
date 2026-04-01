#!/usr/bin/env bash
# CAST TeammateIdle hook
# Fired when an agent team teammate goes idle.
# Exit 0 = done (acceptable). Exit 2 = send feedback to keep working.

set -euo pipefail

INPUT=$(cat)

# Check if teammate produced any output
RESULT=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null || echo "")

# Helper: emit event to cast.db (best-effort, never fail)
_emit_idle_event() {
  local event_type="$1"
  local reason="${2:-}"
  if [ -f "${HOME}/.claude/scripts/cast-events.sh" ]; then
    # shellcheck source=/dev/null
    source "${HOME}/.claude/scripts/cast-events.sh" 2>/dev/null || true
    if declare -f cast_emit_event >/dev/null 2>&1; then
      cast_emit_event "$event_type" "{\"agent\":\"teammate\",\"reason\":\"${reason}\"}" 2>/dev/null || true
    fi
  fi
}

if [ -z "$RESULT" ]; then
  _emit_idle_event "teammate_idle_block" "empty_result" || true
  echo '{"feedback": "Your task produced no output. Please complete the assigned work before going idle. Review your task description and produce the required artifacts."}'
  exit 2
fi

# Check for placeholder/incomplete markers
if echo "$RESULT" | grep -qiE '(TODO|FIXME|PLACEHOLDER|NOT IMPLEMENTED|to be implemented)'; then
  _emit_idle_event "teammate_idle_block" "placeholder_markers" || true
  echo '{"feedback": "Your output contains TODO or placeholder markers. Please complete the implementation before going idle."}'
  exit 2
fi

_emit_idle_event "teammate_idle_pass" "" || true
exit 0
