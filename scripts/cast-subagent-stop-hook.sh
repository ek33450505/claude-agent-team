#!/bin/bash
# cast-subagent-stop-hook.sh — CAST SubagentStop hook (thin wrapper)
# Hook event: SubagentStop
#
# Fires when a subagent stops (naturally or at turn limit).
# This wrapper does the minimum bash-owned work and delegates ALL telemetry to a
# single parse-once python process (cast_subagent_stop.py):
#   1. Read stdin once → export CAST_STOP_INPUT
#   2. Run cast_subagent_stop.py (parses once; runs stages 0-17)
#   3. Pass through its hookSpecificOutput stdout lines
#   4. eval ONLY its shlex-quoted __CAST_TAIL__ sentinel block
#   5. Step 2.8 status-writer.sh call gated on $CAST_GATE_MATCH (bash-owned surface)
#   6. Chain cast-queue-add.sh successor loop gated on $CAST_SUCCESSORS (bash-owned surface)
#
# Exit codes:
#   0 — always (hook must not block the parent session)

# SubagentStop fires inside the parent session — CLAUDE_SUBPROCESS is NOT set here.
# No subprocess guard needed.

# Never fail loudly — a broken hook must not interrupt the parent session.
set +e

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
HOOK_ERROR_LOG="${HOME}/.claude/logs/hook-errors.log"
if ! { mkdir -p "$(dirname "$HOOK_ERROR_LOG")" 2>/dev/null && touch "$HOOK_ERROR_LOG" 2>/dev/null; }; then
  HOOK_ERROR_LOG="/dev/null"
fi

CAST_DIR="${HOME}/.claude/cast"
EVENTS_DIR="${CAST_DIR}/events"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
# Export HOOK_DIR and CAST_HOOK_DIR so the python process can locate sibling
# scripts (cast_db.py/log_hook_failure, cast-redact.py, etc.).
export HOOK_DIR
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
export CAST_HOOK_DIR="${CAST_HOOK_DIR:-$HOOK_DIR}"

mkdir -p "$EVENTS_DIR" 2>/dev/null || true

# Read stdin once
INPUT="$(cat 2>/dev/null)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# ── Opt-in raw-stdin capture (debug) ─────────────────────────────────────────
# Enabled by CREATING the directory; disabled by removing it. No env plumbing and
# no settings change, so it can never switch itself on. Capped so it cannot fill
# the disk. Local-only and off by default: the payload contains full agent output.
# Exists because nothing else in the hook chain records the raw payload, which is
# why the SubagentStop unknown-agent question stayed INFERRED
# (research/v10-attribution-gap-stop-ticks.md §3).
_CAST_STDIN_CAPTURE_DIR="${CAST_DIR}/debug/stdin-capture"
if [ -d "$_CAST_STDIN_CAPTURE_DIR" ]; then
  _cap_count="$(find "$_CAST_STDIN_CAPTURE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d '[:space:]')"
  # Degrade a malformed CAP to the DEFAULT, never to "off": an unvalidated value
  # makes `[` exit 2 and silently disables the capture, and an empty capture dir
  # then reads as "no events observed" — a conclusion drawn from an instrument
  # that was never running.
  # The `??????????*` arm rejects 10-or-more-digit values. Those PASS an all-digits
  # test but still overflow `[ -lt ]` (> 2^63-1 → "integer expected", rc 2), which
  # is precisely the bug this guard exists to prevent.
  _cap_max="${CAST_STDIN_CAPTURE_MAX:-500}"
  case "$_cap_max" in ''|*[!0-9]*|??????????*) _cap_max=500 ;; esac
  # Degrade a malformed COUNT to the CAP — deliberately the OPPOSITE direction from
  # the cap above. An unreadable count must not be read as "empty" and licence an
  # unbounded write; bounding disk use is the whole point of the cap.
  case "$_cap_count" in ''|*[!0-9]*|??????????*) _cap_count="$_cap_max" ;; esac
  if [ "$_cap_count" -lt "$_cap_max" ]; then
    printf '%s' "$INPUT" \
      > "${_CAST_STDIN_CAPTURE_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-$$.json" 2>/dev/null || true
  fi
fi

# Export the raw payload for the python process. Identical trust boundary to the
# old hook — the JSON is never interpolated into any source, only read from env.
export CAST_STOP_INPUT="$INPUT"

# Shared Status-contract helper — sourced only for the wrapper's own no-op
# fallback path (exemption classification itself lives in the python process).
if [ -r "${HOME}/.claude/scripts/cast-status-contract.sh" ]; then
  # shellcheck source=/dev/null
  . "${HOME}/.claude/scripts/cast-status-contract.sh"
fi

# ── Run the single parse-once python process ─────────────────────────────────
# It parses CAST_STOP_INPUT once, runs every telemetry stage (each isolated in
# its own try/except), prints hookSpecificOutput JSON to stdout, and terminates
# with a shlex-quoted __CAST_TAIL__ sentinel block for the two bash-owned surfaces.
_PY_OUT="$(CAST_DB_PATH="$DB_PATH" CAST_HOOK_DIR="$HOOK_DIR" \
    python3 "$HOOK_DIR/cast_subagent_stop.py" 2>>"$HOOK_ERROR_LOG" || true)"

# Split the python stdout: pass through everything OUTSIDE the sentinel block
# (the hookSpecificOutput JSON lines) and collect ONLY the block for eval.
_TAIL_RAW=""
_IN_TAIL=0
while IFS= read -r _line; do
  if [ "$_line" = "__CAST_TAIL_BEGIN__" ]; then
    _IN_TAIL=1
    continue
  fi
  if [ "$_line" = "__CAST_TAIL_END__" ]; then
    _IN_TAIL=0
    continue
  fi
  if [ "$_IN_TAIL" = "1" ]; then
    _TAIL_RAW="${_TAIL_RAW}${_line}"$'\n'
  else
    printf '%s\n' "$_line"
  fi
done <<< "$_PY_OUT"

# Safety contract: shlex.quote() is applied to EVERY field emitted in the
# __CAST_TAIL__ block (see cast_subagent_stop.py:stage17_tail — the eval below is
# safe ONLY because of that quoting). Removing shlex.quote would open a
# shell-injection path: arbitrary agent output flows into an evaluated string.
# Do NOT eval _TAIL_RAW from any source that skips that quoting step.
eval "${_TAIL_RAW}" 2>/dev/null || true

# Apply defaults for any tail var the eval may have left unset.
CAST_GATE_MATCH="${CAST_GATE_MATCH:-}"
CAST_SUCCESSORS="${CAST_SUCCESSORS:-}"
SAFE_AGENT="${SAFE_AGENT:-}"
SAFE_SESSION_ID="${SAFE_SESSION_ID:-}"

# ── Step 2.8: Policy-gate completion record (v9 P-trust) ─────────────────────
# Records the agent's real self-reported terminal verdict to
# ~/.claude/agent-status/<agent>-<ts>.json. cast-git-guard.py reads the MOST
# RECENT such record and clears requires_agent BLOCK policies only for DONE /
# DONE_WITH_CONCERNS. A truncated agent (no recognized status) → CAST_GATE_MATCH
# empty → no file written → gate stays blocked. Gate value computed once by the
# python process (last-match-wins, non-exempt only).
if [[ -n "$CAST_GATE_MATCH" ]]; then
  if [[ -r "${HOME}/.claude/scripts/status-writer.sh" ]]; then
    # shellcheck source=/dev/null
    . "${HOME}/.claude/scripts/status-writer.sh" 2>/dev/null || true
  fi
  if command -v cast_write_status >/dev/null 2>&1; then
    # Neutral summary (defense-in-depth; the reader checks the structured status
    # field). 'subagent completion record' avoids any status keyword.
    cast_write_status \
      "$CAST_GATE_MATCH" \
      "subagent completion record" \
      "$SAFE_AGENT" \
      "" \
      "" 2>/dev/null || true
  fi
fi

# ── Step 4: Chain dispatch (pipeline automation) ──────────────────────────────
# CAST_SUCCESSORS is the newline-joined chain-map successor list for this agent
# (computed by the python process only when the agent completed DONE). Enqueue
# each via cast-queue-add.sh. Best-effort, never blocks the hook.
QUEUE_ADD="${HOME}/.claude/scripts/cast-queue-add.sh"
if [[ -n "$CAST_SUCCESSORS" ]] && [ -f "$QUEUE_ADD" ]; then
  while IFS= read -r successor; do
    [ -n "$successor" ] && bash "$QUEUE_ADD" "$successor" "$SAFE_SESSION_ID" 2>/dev/null || true
  done <<< "$CAST_SUCCESSORS"
fi

exit 0
