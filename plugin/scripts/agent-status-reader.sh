#!/bin/bash
# agent-status-reader.sh — CAST PostToolUse hook for agent status propagation
# Hook event: PostToolUse
#
# Purpose:
#   After a subagent writes a status file via cast_write_status, this hook reads
#   the latest file in ~/.claude/agent-status/ and acts on it:
#
#   BLOCKED           → hard-block the session (exit 2) with [CAST-HALT] directive
#                       Also tracks per-session BLOCKED counter; on 3rd consecutive
#                       BLOCKED, emits [CAST-ESCALATE] advisory suggesting escalation
#   DONE_WITH_CONCERNS → inject [CAST-REVIEW] hookSpecificOutput for main session review
#   DONE              → resets BLOCKED counter; exits 0 silently
#   NEEDS_CONTEXT / missing file → exit 0 silently
#
# CAST-TIMEOUT:
#   On each invocation, checks session start epoch and recent commit events.
#   If session has run 90+ minutes without a commit in the last 60 min,
#   injects a soft advisory suggesting /commit or /fresh.
#
# IMPORTANT — inverted subprocess guard:
#   Unlike route.sh and post-tool-hook.sh (which run in the MAIN session),
#   this hook fires inside subagent context (CLAUDE_SUBPROCESS=1).
#   We must EXIT EARLY when NOT in a subagent — the main session has no status to read.

# Inverted guard: only run inside a subagent process
if [ "${CLAUDE_SUBPROCESS:-0}" != "1" ]; then exit 0; fi

set -euo pipefail

CAST_STATUS_DIR="${CAST_STATUS_DIR:-${HOME}/.claude/agent-status}"
# The session id reaches file names: strict token only (else "default"), capped at 64.
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
case "$SESSION_ID" in '' | *[!A-Za-z0-9_-]*) SESSION_ID="default" ;; esac
SESSION_ID="${SESSION_ID:0:64}"
# Per-session state (BLOCKED counter, session-start epoch) lives in a 0700 dir we own under
# ~/.claude -- NOT in /tmp, where an agent can pre-plant symlinks that a write would follow.
# A symlinked / foreign-owned dir disables the state files (STATE_OK=0) instead of being used.
CAST_STATE_DIR="${HOME}/.claude/cast-state"
STATE_OK=0
if [ ! -L "$CAST_STATE_DIR" ]; then
  mkdir -p "${HOME}/.claude" 2>/dev/null || true
  mkdir -m 700 "$CAST_STATE_DIR" 2>/dev/null || true
  if [ -d "$CAST_STATE_DIR" ] && [ ! -L "$CAST_STATE_DIR" ] && [ -O "$CAST_STATE_DIR" ] \
     && chmod 700 "$CAST_STATE_DIR" 2>/dev/null; then
    STATE_OK=1
  fi
fi
BLOCKED_COUNT_PREFIX=""
SESSION_EPOCH_FILE=""
if [ "$STATE_OK" -eq 1 ]; then
  BLOCKED_COUNT_PREFIX="${CAST_STATE_DIR}/cast-blocked-${SESSION_ID}"
  SESSION_EPOCH_FILE="${CAST_STATE_DIR}/cast-session-start-${SESSION_ID}.epoch"
fi
CAST_EVENTS_DIR="${HOME}/.claude/cast/events"
TIMEOUT_MSG=""

# --- CAST-TIMEOUT: session duration check ---
# Create session start epoch file if absent; suppress errors if /tmp is not writable
CURRENT_EPOCH="$(date +%s)"
# O_EXCL|O_NOFOLLOW: create only when absent, never through a symlink.
CAST_EPOCH_FILE="$SESSION_EPOCH_FILE" CAST_EPOCH_VAL="$CURRENT_EPOCH" python3 -I -c "
import os
f = os.environ.get('CAST_EPOCH_FILE','')
v = os.environ.get('CAST_EPOCH_VAL','')
if f:
    try:
        fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as ef:
            ef.write(v)
    except Exception:
        pass
" 2>/dev/null || true

SESSION_START="$CURRENT_EPOCH"
if [ -n "$SESSION_EPOCH_FILE" ] && [ -f "$SESSION_EPOCH_FILE" ] && [ ! -L "$SESSION_EPOCH_FILE" ]; then
  SESSION_START="$(cat "$SESSION_EPOCH_FILE" 2>/dev/null || echo "$CURRENT_EPOCH")"
fi
# numeric only: this value feeds $(( )), where arbitrary text is code
case "$SESSION_START" in '' | *[!0-9]*) SESSION_START="$CURRENT_EPOCH" ;; esac
SESSION_AGE=$(( CURRENT_EPOCH - SESSION_START ))

if [ "$SESSION_AGE" -gt 5400 ]; then
  # Check for a commit event in the last 3600 seconds
  RECENT_COMMIT_FOUND=0
  if [ -d "$CAST_EVENTS_DIR" ]; then
    CUTOFF=$(( CURRENT_EPOCH - 3600 ))
    # Look for commit events in event files; check file mtime as proxy
    while IFS= read -r -d '' evfile; do
      FILE_MTIME="$(stat -f '%m' "$evfile" 2>/dev/null || echo 0)"
      if [ "$FILE_MTIME" -ge "$CUTOFF" ]; then
        if grep -q '"event_type"\s*:\s*"task_completed"' "$evfile" 2>/dev/null && \
           grep -q '"agent"\s*:\s*"commit"' "$evfile" 2>/dev/null; then
          RECENT_COMMIT_FOUND=1
          break
        fi
        # Also match commit in artifact_written or task_claimed events
        if grep -q '"commit"' "$evfile" 2>/dev/null; then
          RECENT_COMMIT_FOUND=1
          break
        fi
      fi
    done < <(find "$CAST_EVENTS_DIR" -name "*.json" -print0 2>/dev/null)
  fi

  if [ "$RECENT_COMMIT_FOUND" -eq 0 ]; then
    # Collect into a variable instead of printing immediately.
    # If the status-file check below also produces output, two JSON objects on
    # stdout would cause the second to be silently dropped by the hook infra.
    # We defer printing until after the status check, and only print when the
    # status is non-blocking (empty / DONE / NEEDS_CONTEXT).
    TIMEOUT_MSG="$(python3 -I -c "
import json
msg = '[CAST-TIMEOUT] Session running 90+ minutes without a commit event. Consider: /commit to checkpoint progress, or /fresh to start a clean context.'
output = {
    'hookSpecificOutput': {
        'hookEventName': 'PostToolUse',
        'additionalContext': msg
    }
}
print(json.dumps(output))
" 2>/dev/null)"
  fi
fi

# --- Status file check ---

# Nothing to read if the directory does not exist yet
if [ ! -d "$CAST_STATUS_DIR" ]; then exit 0; fi

# Find the latest status file (sort by filename which encodes UTC timestamp)
LATEST_FILE="$(ls -1 "$CAST_STATUS_DIR"/*.json 2>/dev/null | sort | tail -1 || echo "")"

[ -z "$LATEST_FILE" ] && exit 0

# Canonicalize and bound-check the path before reading
# Use realpath on both sides — macOS mktemp paths can be symlinks (/var → /private/var)
REAL_PATH="$(realpath "$LATEST_FILE" 2>/dev/null)" || REAL_PATH=""
REAL_HOME="$(realpath "$HOME" 2>/dev/null)" || REAL_HOME="$HOME"
if [[ -z "$REAL_PATH" || "$REAL_PATH" != "$REAL_HOME/"* ]]; then exit 0; fi

# Parse status and summary using python3 stdlib only
CAST_STATUS_FILE="$REAL_PATH" \
CAST_BLOCKED_COUNT_PREFIX="$BLOCKED_COUNT_PREFIX" \
python3 -I -c "
import json, os, sys, time, subprocess

filepath = os.environ.get('CAST_STATUS_FILE', '')
blocked_count_prefix = os.environ.get('CAST_BLOCKED_COUNT_PREFIX', '')

import re as _re, unicodedata as _ud

def _safe_name(v):
    # agent names reach file names and model context: plain token only, else unknown
    return v if isinstance(v, str) and _re.fullmatch(r'[A-Za-z0-9_-]{1,64}', v) else 'unknown'

def _clean(v, limit):
    # free text from a status file any process can write, rendered into model context / stdout:
    # strip control, format (bidi, zero-width), surrogate and U+2028/2029 chars, neutralise [ ] so a
    # forged [CAST-...] directive cannot appear, cap the length
    if v is None:
        return ''
    if not isinstance(v, str):
        v = str(v)
    v = _re.sub(r'[\r\n\t]', ' ', v)
    v = ''.join(c for c in v if _ud.category(c) not in ('Cc', 'Cf', 'Cs', 'Zl', 'Zp'))
    v = v.replace('[', '(').replace(']', ')')
    return v if len(v) <= limit else v[:limit] + '...'

def _read_count(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as cf:
        return int(cf.read().strip())

def _write_count(path, n):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as cf:
        cf.write(str(n))

try:
    with open(filepath) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)

# Age guard: ignore status files older than 60 seconds (stale from prior sessions)
file_mtime = os.path.getmtime(filepath)
age_seconds = time.time() - file_mtime
if age_seconds > 60:
    sys.exit(0)  # Stale file — ignore

status          = d.get('status', '')
agent           = _safe_name(d.get('agent', 'unknown'))
summary         = _clean(d.get('summary', ''), 500)
concerns        = _clean(d.get('concerns') or '', 1000)
chain_dispatched = d.get('chain_dispatched') or []

# --- Persist status to routing-log ---
import datetime as _dt
_log_entry = json.dumps({
    'timestamp': _dt.datetime.now(_dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'session_id': os.environ.get('CLAUDE_SESSION_ID', ''),
    'action': 'agent_complete',
    'matched_route': agent,
    'status': status,
    'summary': (summary or '')[:120]
})
_log_script = os.path.join(os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts')), 'cast-log-append.py')
if os.path.exists(_log_script):
    try:
        subprocess.run([sys.executable, '-I', _log_script], input=_log_entry, text=True, timeout=3, check=False)
    except Exception:
        pass  # logging failure must never break status handling

# Per-agent BLOCKED counter path (scoped to session + agent)
blocked_count_file = f'{blocked_count_prefix}-{agent}.count' if blocked_count_prefix else ''

if status == 'BLOCKED':
    # --- CAST-ESCALATE: per-session BLOCKED counter ---
    current_count = 0
    try:
        current_count = _read_count(blocked_count_file) if blocked_count_file else 0
    except Exception:
        current_count = 0
    current_count += 1
    try:
        if blocked_count_file:
            _write_count(blocked_count_file, current_count)
    except Exception:
        pass

    if current_count >= 3:
        # Escalation path
        msg = (
            f'**[CAST-ESCALATE]** Agent \`{agent}\` has reported BLOCKED {current_count} times this session.\n'
            f'Summary: {summary}'
        )
        if concerns:
            msg += f'\nConcerns: {concerns}'
        msg += (
            '\nOptions: (1) prefix your next prompt with opus: for higher-capability model, '
            '(2) provide missing context manually, '
            '(3) split the task into smaller units.'
        )
    else:
        # Standard BLOCKED path
        msg = (
            f'**[CAST-HALT]** Agent \`{agent}\` is BLOCKED and cannot proceed.\n'
            f'Summary: {summary}'
        )
        if concerns:
            msg += f'\nConcerns: {concerns}'
        msg += '\nResolve the blocker before continuing. Do not retry the blocked operation.'
    print(msg)
    sys.exit(2)

elif status == 'DONE':
    # Reset BLOCKED counter on success
    try:
        if blocked_count_file:
            _write_count(blocked_count_file, 0)
    except Exception:
        pass
    # Surface chain_dispatched info if present so inline session knows the chain fired
    if chain_dispatched:
        # chain_dispatched names are echoed into the model's context: plain agent-name tokens only.
        if not isinstance(chain_dispatched, list):
            chain_dispatched = [chain_dispatched]
        chain_list = ', '.join(_safe_name(a) for a in chain_dispatched[:20])
        directive = (
            f'[CAST-CHAIN-CONFIRMED] Agent {agent} dispatched downstream agent(s): {chain_list}. '
            'Chain is active — do not re-dispatch these agents from the inline session.'
        )
        output = {
            'hookSpecificOutput': {
                'hookEventName': 'PostToolUse',
                'additionalContext': directive
            }
        }
        import json as _json
        print(_json.dumps(output))
    sys.exit(0)

elif status == 'DONE_WITH_CONCERNS':
    directive = (
        f'[CAST-REVIEW] Agent \`{agent}\` completed with concerns.\n'
        f'Summary: {summary}'
    )
    if concerns:
        directive += f'\nConcerns: {concerns}'
    directive += '\nDispatch \`code-reviewer\` (haiku) to review before proceeding.'
    output = {
        'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': directive
        }
    }
    import json as _json
    print(_json.dumps(output))
    sys.exit(0)

elif status == 'NEEDS_CONTEXT':
    directive = (
        f'[CAST-NEEDS-CONTEXT] Agent \`{agent}\` needs more context to proceed.\n'
        f'Summary: {summary}\n'
        'Recommended: dispatch the \`researcher\` agent to gather the missing context, '
        'then re-dispatch the original agent with research findings prepended to its prompt.'
    )
    output = {
        'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': directive
        }
    }
    import json as _json
    print(_json.dumps(output))
    sys.exit(0)

# unknown — exit silently
sys.exit(0)
" 2>/dev/null
STATUS_EXIT="${PIPESTATUS[0]:-$?}"

# If the status check exited cleanly (non-blocking: DONE / NEEDS_CONTEXT / unknown / no file),
# emit the deferred timeout advisory now — if one was collected above.
# BLOCKED (exit 2) and DONE_WITH_CONCERNS take priority; suppress the advisory in those cases.
if [ "$STATUS_EXIT" -eq 0 ] && [ -n "${TIMEOUT_MSG:-}" ]; then
  echo "$TIMEOUT_MSG"
fi

exit "$STATUS_EXIT"
