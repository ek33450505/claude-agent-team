#!/usr/bin/env bash
# cast-config-change-guard.sh -- ConfigChange hook wrapper (S3d follow-up F1b).
#
# Vetoes a hot-reloaded project/local .claude settings change that sets
# `disableAllHooks` or an exec/guard-relevant `env` key. Judgement lives in
# cast_config_change_guard.py (see its docstring for the threat and residuals).
#
# DELIBERATELY NO `CLAUDE_SUBPROCESS` early exit and NO override env var: this
# guard protects that very channel (project/local `env` can set
# CLAUDE_SUBPROCESS / CAST_POLICY_OVERRIDE), so honouring either here would
# hand the attacker the off-switch.
#
# FAIL CLOSED: if the evaluator is missing or exits non-zero, emit a block.
# Exit is always 0 -- the verdict is carried by the JSON `decision`.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALUATOR="$HOOK_DIR/cast_config_change_guard.py"

# stderr -> hook-errors.log (append). Logging must never fail the hook.
ERR_LOG="${HOME:-/nonexistent}/.claude/logs/hook-errors.log"
( umask 077; mkdir -p "$(dirname "$ERR_LOG")" ) 2>/dev/null || true
{ : >>"$ERR_LOG"; } 2>/dev/null || ERR_LOG=/dev/null

fail_closed() {
  printf '%s\n' '{"decision":"block","reason":"cast-config-change-guard: evaluator failed"}'
  exit 0
}

if [[ ! -f "$EVALUATOR" ]]; then
  printf '%s cast-config-change-guard: evaluator missing: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVALUATOR" >>"$ERR_LOG" 2>/dev/null || true
  fail_closed
fi

out=""
rc=0
set +e
out="$(python3 -I "$EVALUATOR" 2>>"$ERR_LOG")"; rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  printf '%s cast-config-change-guard: evaluator exited %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >>"$ERR_LOG" 2>/dev/null || true
  fail_closed
fi

if [[ -n "$out" ]]; then
  printf '%s\n' "$out"
fi
exit 0
