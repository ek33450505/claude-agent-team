#!/usr/bin/env bash
# cast-filechanged-hook.sh — observability hook fired when matched files change.
# Matcher in settings.json: .envrc|.env|.cast|cast.json
set -euo pipefail

if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null || echo "")"
CHANGE_TYPE="$(printf '%s' "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("change_type",""))' 2>/dev/null || echo "")"

if [[ -f "${HOME}/.claude/scripts/cast-events.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.claude/scripts/cast-events.sh"
  cast_emit_event 'file_changed' 'filechanged-hook' "${FILE_PATH}" '' "type=${CHANGE_TYPE}" 'INFO' 2>/dev/null || true
fi

exit 0
