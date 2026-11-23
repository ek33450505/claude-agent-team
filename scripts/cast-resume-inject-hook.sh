#!/bin/bash
# cast-resume-inject-hook.sh — SessionStart hook
# Injects the latest resume distillate for the current repo at session start.
# Selects a hand-authored override when at least as fresh as the auto floor,
# else the auto distillate (cast-resume-scaffold.py output). Silent-degrades on
# any error — must NEVER block a session.
# Sets hookSpecificOutput.sessionTitle (CC >= 2.1.152) only for a manual handoff when stdin is a JSON object whose source is exactly "startup" (fail-closed).

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

_log_error() {
  # Sanitize the whole message ($0 included): no CR/ESC/ANSI/newline log spoofing.
  local msg
  msg="$(printf '%s' "$0: $1" | LC_ALL=C tr -c '[:print:]' '?')" || msg="?"
  msg="${msg:0:1024}" # ASCII after tr (chars == bytes): bound every caller, $0 included
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $msg" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

# Drain the hook payload on early exits (HEAD always read it with cat), so the writer never blocks.
# Bounded: an endless stdin must not spin until the hook timeout.
_drain() { head -c 16777216 > /dev/null 2>&1 || true; }   # bounded (== DISCARD_CAP): endless stdin cannot spin


# Resolve repo -> slug (matches cast-resume-scaffold.py: slug = basename of git toplevel)
# Runs UNSANDBOXED in an agent-writable cwd: bare git would execute repo-local config an
# agent plants (core.fsmonitor, filters, hooks, gpg.program, ...). Use the hardened
# cast_git_safe primitive from the lib in THIS script's absolute dir; if it will not
# load, never fall back to bare git -> silent degrade.
_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
unset _CAST_HOOK_LIB_LOADED
unset -f cast_git_safe 2>/dev/null || true
# shellcheck source=/dev/null
# (-r first: bash 3.2 exits the shell silently on a failed `source` of a missing file.)
if [[ ! -r "${_DIR}/cast-hook-lib.sh" ]] || ! source "${_DIR}/cast-hook-lib.sh" 2>/dev/null || ! declare -F cast_git_safe >/dev/null 2>&1; then _drain; exit 0; fi
REPO="$(cast_git_safe "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO" ]; then _drain; exit 0; fi   # not a git repo -> silent degrade
SLUG="$(basename "$REPO")"

OUT_DIR="${HOME}/.claude/resume-prompts"
if [ ! -d "$OUT_DIR" ]; then _drain; exit 0; fi

# Selection, read and JSON build all happen in ONE python process (cast-resume-inject.py);
# the hook payload flows to it on stdin. Contract: rc 0 + JSON = pass through; rc 0 + empty
# = nothing chosen; rc 3 (unreadable / not regular) and rc 4 (empty body) print only the
# chosen file's basename; any other rc = build failure.
if [[ ! -f "${_DIR}/cast-resume-inject.py" || ! -r "${_DIR}/cast-resume-inject.py" ]]; then
  _log_error "resume-inject: helper missing or unreadable: cast-resume-inject.py"
  _drain
  exit 0
fi
JSON_RC=0
OUT="$(python3 -I "${_DIR}/cast-resume-inject.py" "$OUT_DIR" "$SLUG" 2>/dev/null)" || JSON_RC=$?
case "$JSON_RC" in 0 | 3 | 4) ;; *) _drain ;; esac   # python consumed stdin on rc 0/3/4; else it may have died first
if [ "$JSON_RC" -eq 0 ]; then
  if [ -n "$OUT" ]; then printf '%s\n' "$OUT"; fi
else
  # Cap the name at 200 chars; _log_error sanitizes the whole message.
  LOG_NAME="${OUT:0:200}"
  case "$JSON_RC" in
    3) _log_error "resume-inject: chosen handoff unreadable or not a regular file: $LOG_NAME" ;;
    4) _log_error "resume-inject: chosen handoff is empty: $LOG_NAME" ;;
    *) _log_error "python3 JSON build failed in cast-resume-inject-hook.sh" ;;
  esac
fi

exit 0
