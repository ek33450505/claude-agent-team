#!/usr/bin/env bash
# cast-cwdchanged-hook.sh — observability hook fired by Claude Code when cwd changes.
# Logs the cwd change to cast.db via cast-events.sh.
# Also detects repo_class from <new_cwd>/.claude/cast.json and exports CAST_REPO_CLASS.
# Always exits 0 (async hook contract).
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

# ── Step 1: Emit observability event ──────────────────────────────────
# Emit event (best-effort; never fail the hook)
if [[ -f "${HOME}/.claude/scripts/cast-events.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.claude/scripts/cast-events.sh"
  cast_emit_event 'cwd_changed' 'cwdchanged-hook' "${NEW_CWD}" '' "from=${PREVIOUS_CWD}" 'INFO' 2>/dev/null || true
fi

# ── Step 2: Detect repo_class from .claude/cast.json ──────────────────
REPO_CLASS="personal"  # Default fallback
CAST_JSON_PATH="${NEW_CWD}/.claude/cast.json"

if [[ -f "$CAST_JSON_PATH" ]]; then
  # Try to extract repo_class field (graceful fallback to default)
  # Use heredoc with environment variable to avoid code injection
  REPO_CLASS=$(CAST_JSON_PATH="$CAST_JSON_PATH" python3 << 'PYTHON_BLOCK'
import json, os
try:
    with open(os.environ['CAST_JSON_PATH']) as f:
        d = json.load(f)
        print(d.get('repo_class', 'personal'))
except Exception:
    print('personal')
PYTHON_BLOCK
) || REPO_CLASS="personal"
fi

# ── Step 3: Export CAST_REPO_CLASS via hookSpecificOutput ──────────────
# Emit JSON to stdout so Claude Code can set CAST_REPO_CLASS in the session environment.
# hookEventName must match the hook event type triggering this script (CwdChanged).
REPO_CLASS="$REPO_CLASS" python3 << 'PYTHON_END'
import json, os
output = {
    "hookSpecificOutput": {
        "hookEventName": "CwdChanged",
        "environment": {
            "CAST_REPO_CLASS": os.environ.get("REPO_CLASS", "personal")
        }
    }
}
print(json.dumps(output))
PYTHON_END

# ── Step 4: Log repo_class transition to cast.db (best-effort) ─────────
if [[ -f "${HOME}/.claude/scripts/cast-events.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.claude/scripts/cast-events.sh"
  cast_emit_event 'repo_class_detected' 'cwdchanged-hook' "$REPO_CLASS" '' "cwd=${NEW_CWD}" 'INFO' 2>/dev/null || true
fi

exit 0
