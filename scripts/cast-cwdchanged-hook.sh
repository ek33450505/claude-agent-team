#!/usr/bin/env bash
# cast-cwdchanged-hook.sh — observability hook fired by Claude Code when cwd changes.
# Logs the cwd change to cast.db via cast-events.sh. Always exits 0 (async hook contract).
set -euo pipefail

# Subprocess bypass
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# Read hook input (JSON on stdin per Claude Code hook contract)
INPUT="$(cat 2>/dev/null || true)"

# Extract previous_cwd and new_cwd via python3 (safe parsing)
PREVIOUS_CWD="$(printf '%s' "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("previous_cwd",""))' 2>/dev/null || echo "")"
NEW_CWD="$(printf '%s' "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("new_cwd",""))' 2>/dev/null || echo "")"

# Emit event (best-effort; never fail the hook)
if [[ -f "${HOME}/.claude/scripts/cast-events.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.claude/scripts/cast-events.sh"
  cast_emit_event 'cwd_changed' 'cwdchanged-hook' "${NEW_CWD}" '' "from=${PREVIOUS_CWD}" 'INFO' 2>/dev/null || true
fi

exit 0
