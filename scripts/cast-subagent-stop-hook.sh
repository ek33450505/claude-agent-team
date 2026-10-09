#!/bin/bash
# cast-subagent-stop-hook.sh — CAST SubagentStop hook (thin wrapper)
# Hook event: SubagentStop
#
# Fires when a subagent stops (naturally or at turn limit).
# This wrapper does the minimum bash-owned work and delegates ALL telemetry to a
# single parse-once python process (cast_subagent_stop.py):
#   1. Read stdin once → hold in $INPUT; hand it to each python pass on STDIN (--stdin)
#   2. Run cast_subagent_stop.py --gate-only (fast: parses once, runs NO stages);
#      eval ONLY its shlex-quoted __CAST_TAIL__ sentinel block (S3d-5)
#   3. Step 2.8 status-writer.sh call gated on $CAST_GATE_MATCH (bash-owned surface) —
#      runs BEFORE telemetry so a slow/killed telemetry pass cannot lose the record
#   4. Run cast_subagent_stop.py (full pass: parses once; runs stages 0-17)
#   5. Pass through its hookSpecificOutput stdout lines; eval ONLY its tail block
#   6. Chain cast-queue-add.sh successor loop gated on $CAST_SUCCESSORS (bash-owned surface)
#   Fallbacks (see "Pass orchestration"): an OLD python that ignores --gate-only is
#   detected from its tail and its pass 1 is treated AS the full pass (pass 2 skipped);
#   a gate pass that emits no tail defers Step 2.8 to after pass 2. Step 2.8 runs once.
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

# The raw payload reaches each python pass on STDIN (``--stdin``), NOT via an exported
# env var: an env var is capped (E2BIG — ~128 KiB per string on Linux, ~1 MiB for the
# whole env+argv block on macOS), so an oversized payload used to fail the exec and
# write NO record, silently. `printf` is a builtin (no exec arg limit) and the pipe has
# no size cap. Same trust boundary as before — the JSON is never interpolated into any
# source. Clear any inherited value so a stale env can never be mistaken for the payload.
unset CAST_STOP_INPUT

# Shared Status-contract helper — sourced only for the wrapper's own no-op
# fallback path (exemption classification itself lives in the python process).
if [ -r "${HOME}/.claude/scripts/cast-status-contract.sh" ]; then
  # shellcheck source=/dev/null
  . "${HOME}/.claude/scripts/cast-status-contract.sh"
fi

# ── Tail-block helper (the ONE place the eval safety contract lives) ─────────
# _load_tail <python-stdout>: split the python stdout into (a) the sentinel block,
# which is eval'd here, and (b) everything OUTSIDE it, left in _PASSTHRU for the
# caller to print (full pass) or discard (gate pass).
#
# Safety contract: shlex.quote() is applied to EVERY field emitted in the
# __CAST_TAIL__ block (see cast_subagent_stop.py:_emit_tail — the eval below is
# safe ONLY because of that quoting). Removing shlex.quote would open a
# shell-injection path: arbitrary agent output flows into an evaluated string.
# Do NOT eval a tail block from any source that skips that quoting step.
_load_tail() {
  _TAIL_RAW=""
  _PASSTHRU=""
  local _in_tail=0 _line
  while IFS= read -r _line; do
    if [ "$_line" = "__CAST_TAIL_BEGIN__" ]; then
      _in_tail=1
      continue
    fi
    if [ "$_line" = "__CAST_TAIL_END__" ]; then
      _in_tail=0
      continue
    fi
    if [ "$_in_tail" = "1" ]; then
      _TAIL_RAW="${_TAIL_RAW}${_line}"$'\n'
    else
      _PASSTHRU="${_PASSTHRU}${_line}"$'\n'
    fi
  done <<< "$1"
  eval "${_TAIL_RAW}" 2>/dev/null || true
}

# ── Step 2.8: Policy-gate completion record (v9 P-trust) ─────────────────────
# S3d-5: this runs BEFORE the telemetry pass (right after the fast --gate-only
# python pass), not after it. The full pass runs stages 0-17 and stage 9 (claimed-
# work verifier) alone can take 50-100 s on large outputs; with the SubagentStop
# hook timeout (~15 s) a slow stage killed the hook before any record was written,
# so a security/devops requires_agent review never unblocked. The record depends
# only on parse-once data, so it is written first and the telemetry cannot lose it.
# The full pass must NOT write a second record — Step 2.8 runs exactly once.
# Records the agent's real self-reported terminal verdict to
# ~/.claude/agent-status/<agent>-<ts>.json. cast-git-guard.py reads the MOST
# RECENT such record and clears requires_agent BLOCK policies only for DONE /
# DONE_WITH_CONCERNS. A truncated agent (no recognized status) → CAST_GATE_MATCH
# empty → no file written → gate stays blocked. Gate value computed once by the
# python process (compute_gate_match, non-exempt only): ASYMMETRIC and
# most-conservative-wins (BLOCKED > NEEDS_CONTEXT > DONE_WITH_CONCERNS > DONE) —
# passing verdicts only from an unfenced line-anchored `Status: X` or a closed
# ```json status``` fence; BLOCKED/NEEDS_CONTEXT from ANY line, fence-independent
# and unanchored. NOT last-match-wins (quoted text must never override a block).
# Identity: the gate trusts ONLY the record's `session_id` and `agent_type`
# content fields, which only this hook supplies (args 6/7). `agent_type` is the
# roster type read from Claude Code's subagent sidecar, NEVER the dispatch name
# (a read-only Explore agent dispatched as name "security" would otherwise write
# a `security` record). The filename and the `agent` field stay display-only; an
# empty SAFE_ROSTER_TYPE (untrusted/ambiguous sidecar) omits `agent_type`.
# Called from exactly ONE place per stop (see the pass orchestration below); the body
# is single-sourced here so the quoting/identity contract cannot drift between callers.
_write_gate_record() {
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
        "$CAST_GATE_REASON" \
        "" \
        "$SAFE_SESSION_ID" \
        "$SAFE_ROSTER_TYPE" >/dev/null 2>&1 || true
    fi
  fi
}

# ── Pass orchestration ───────────────────────────────────────────────────────
# Pass 1 (--gate-only) is classified by what its tail block shows:
#   full — CAST_SUCCESSORS was assigned. A new --gate-only structurally omits that var
#          (cast_subagent_stop.py:_emit_tail include_successors=False; test S3d-5d
#          refutes it), while every full pass emits it unconditionally from stage 17.
#          So it means an OLD cast_subagent_stop.py ignored the flag (partial deploy)
#          and already ran the whole pipeline: treat pass 1 AS the full pass — print
#          its passthrough, use its tail for Step 2.8 and Step 4, SKIP pass 2.
#          (Chosen over "non-tail stdout non-empty": a full pass prints
#          hookSpecificOutput only conditionally, stage 17's tail is unconditional.)
#   gate — tail block present, no CAST_SUCCESSORS: the normal fast pass. Step 2.8 now.
#   none — NO tail block (the gate pass died, or a heartbeat tick / main-session Stop
#          emitted nothing). Defer Step 2.8 until after pass 2 and write from pass 2's
#          tail: a gate pass killed between a stale DONE record and a genuine BLOCKED
#          stop must not leave the DONE as the newest. A tick emits no tail in pass 2
#          either, so it still writes no record.
# Step 2.8 runs at most once per stop in every mode.
_default_tail_vars() {
  CAST_GATE_MATCH="${CAST_GATE_MATCH:-}"
  CAST_GATE_REASON="${CAST_GATE_REASON:-}"
  CAST_SUCCESSORS="${CAST_SUCCESSORS:-}"
  SAFE_AGENT="${SAFE_AGENT:-}"
  SAFE_SESSION_ID="${SAFE_SESSION_ID:-}"
  SAFE_ROSTER_TYPE="${SAFE_ROSTER_TYPE:-}"
}

# ── Pass 1: fast gate-only python process (S3d-5) ────────────────────────────
# Parses the stdin payload once, applies the same identity guards as the full pass,
# runs NO telemetry stage, and emits ONLY the gate tail block (CAST_GATE_MATCH /
# SAFE_*). Its stdout outside the tail block is discarded unless the flag was ignored
# (mode "full" below) — the full pass is otherwise the sole hookSpecificOutput source.
# Clear EVERY tail var first: an inherited value in the hook's environment must never
# survive `_default_tail_vars` into `_write_gate_record` (a tick emits no tail in either
# pass, so nothing would overwrite it). `unset` also lets the CAST_SUCCESSORS probe below
# tell "assigned by pass 1's tail" from "never set".
unset CAST_GATE_MATCH CAST_GATE_REASON SAFE_AGENT SAFE_SESSION_ID SAFE_ROSTER_TYPE CAST_SUCCESSORS
_GATE_OUT="$(printf '%s' "$INPUT" | CAST_DB_PATH="$DB_PATH" CAST_HOOK_DIR="$HOOK_DIR" \
    python3 -E -s "$HOOK_DIR/cast_subagent_stop.py" --gate-only --stdin 2>>"$HOOK_ERROR_LOG" || true)"
_load_tail "$_GATE_OUT"
_PASS1_PASSTHRU="$_PASSTHRU"
_PASS1_MODE="none"
if [[ -n "${CAST_SUCCESSORS+x}" ]]; then
  _PASS1_MODE="full"
elif [[ -n "$_TAIL_RAW" ]]; then
  _PASS1_MODE="gate"
fi
_default_tail_vars

if [[ "$_PASS1_MODE" = "full" ]]; then
  # Old python ignored --gate-only: pass 1 WAS the full pass. Do not run it twice.
  printf '%s' "$_PASS1_PASSTHRU"
  _write_gate_record
else
  if [[ "$_PASS1_MODE" = "gate" ]]; then
    # S3d-5: record BEFORE telemetry. Chain successors come from the FULL pass only.
    CAST_SUCCESSORS=""
    _write_gate_record
  fi

  # ── Pass 2: full parse-once python process (telemetry, stages 0-17) ────────
  # It parses the stdin payload once, runs every telemetry stage (each isolated in
  # its own try/except), prints hookSpecificOutput JSON to stdout, and terminates
  # with a shlex-quoted __CAST_TAIL__ sentinel block (CAST_SUCCESSORS is consumed
  # by Step 4; in mode "gate" the gate vars were already acted on above).
  _PY_OUT="$(printf '%s' "$INPUT" | CAST_DB_PATH="$DB_PATH" CAST_HOOK_DIR="$HOOK_DIR" \
      python3 -E -s "$HOOK_DIR/cast_subagent_stop.py" --stdin 2>>"$HOOK_ERROR_LOG" || true)"

  # Pass through everything OUTSIDE the sentinel block (the hookSpecificOutput JSON
  # lines); _load_tail has already eval'd ONLY the block.
  _load_tail "$_PY_OUT"
  printf '%s' "$_PASSTHRU"
  _default_tail_vars

  if [[ "$_PASS1_MODE" = "none" ]]; then
    # Gate pass produced no tail: write the (single) record from pass 2's tail.
    _write_gate_record
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
