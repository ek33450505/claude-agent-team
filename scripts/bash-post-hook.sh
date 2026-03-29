#!/bin/bash
# bash-post-hook.sh — CAST PostToolUse hook: audit logging for destructive Bash commands
#
# Fires on every Bash tool use. Matches potentially destructive or notable commands
# and appends a one-line JSON entry to ~/.claude/cast/audit-destructive.jsonl.
#
# Never blocks (always exit 0). Designed to be fast (<100ms).
#
# Severity:
#   high   — rm, git reset/checkout/clean, git push --force
#   medium — npm install, pip install

# Subprocess guard — must be first; prevents subagent re-trigger
[[ "${CLAUDE_SUBPROCESS:-0}" = "1" ]] && exit 0

set -euo pipefail

INPUT="$(cat)"

# Extract the command that was executed (tool_input.command)
# Use jq if available (faster), fall back to python3
if command -v jq &>/dev/null; then
  CMD="$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)" || CMD=""
else
  CMD="$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null)" || CMD=""
fi

if [[ -z "$CMD" ]]; then
  # Warn on stderr if input was non-empty but parse failed
  [[ -n "$INPUT" ]] && echo "[CAST-WARN] bash-post-hook: failed to parse command from tool input" >&2
  exit 0
fi

# Normalize to lowercase for case-insensitive SQL pattern matching
CMD_LOWER="${CMD,,}"

# --- Pattern matching ---
# Using case/grep for speed; severity assigned in the match block.

PATTERN=""
SEVERITY=""

# rm -rf / rm -r (matches -r, -rf, -fr, -Rf, --recursive, etc.)  (high)
if echo "$CMD" | grep -qE '(^|[[:space:]])rm[[:space:]]+-[a-zA-Z]*r'; then
  PATTERN="rm_rf"
  SEVERITY="high"
# git reset --hard  (high)
elif echo "$CMD" | grep -qE '(^|[[:space:]])git[[:space:]]+reset[[:space:]]+--hard'; then
  PATTERN="git_reset_hard"
  SEVERITY="high"
# git push --force / git push -f  (high)
elif echo "$CMD" | grep -qE '(^|[[:space:]])git[[:space:]]+push[[:space:]].*(--force|-f)'; then
  PATTERN="git_push_force"
  SEVERITY="high"
# git checkout . / git checkout -- .  (high)
elif echo "$CMD" | grep -qE '(^|[[:space:]])git[[:space:]]+checkout[[:space:]]+(--[[:space:]]*)?\.'; then
  PATTERN="git_checkout_dot"
  SEVERITY="high"
# git restore .  (high)
elif echo "$CMD" | grep -qE '(^|[[:space:]])git[[:space:]]+restore[[:space:]]+\.'; then
  PATTERN="git_restore_dot"
  SEVERITY="high"
# git clean  (high)
elif echo "$CMD" | grep -qE '(^|[[:space:]])git[[:space:]]+clean'; then
  PATTERN="git_clean"
  SEVERITY="high"
# drop table (case-insensitive)  (high)
elif echo "$CMD_LOWER" | grep -qE 'drop[[:space:]]+table'; then
  PATTERN="drop_table"
  SEVERITY="high"
# npm install  (medium)
elif echo "$CMD" | grep -qE '(^|[[:space:]])npm[[:space:]]+install'; then
  PATTERN="npm_install"
  SEVERITY="medium"
# pip install  (medium)
elif echo "$CMD" | grep -qE '(^|[[:space:]])pip[[:space:]]+install'; then
  PATTERN="pip_install"
  SEVERITY="medium"
fi

# No match — nothing to log
[[ -z "$PATTERN" ]] && exit 0

# --- Append audit entry ---
AUDIT_DIR="${HOME}/.claude/cast"
AUDIT_FILE="${AUDIT_DIR}/audit-destructive.jsonl"

# Ensure audit directory exists
mkdir -p "$AUDIT_DIR" 2>/dev/null || {
  echo "[CAST-WARN] bash-post-hook: cannot create $AUDIT_DIR" >&2
  exit 0
}

# Truncate command preview to 100 chars
CMD_PREVIEW="${CMD:0:100}"

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

python3 -c "
import json, sys
entry = {
    'timestamp': sys.argv[1],
    'session_id': sys.argv[2],
    'command_preview': sys.argv[3],
    'pattern': sys.argv[4],
    'severity': sys.argv[5],
}
print(json.dumps(entry))
" "$TIMESTAMP" "$SESSION_ID" "$CMD_PREVIEW" "$PATTERN" "$SEVERITY" >> "$AUDIT_FILE" 2>/dev/null || true

exit 0
