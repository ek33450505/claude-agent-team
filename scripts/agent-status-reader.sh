#!/bin/bash
# agent-status-reader.sh — CAST PostToolUse hook for agent status propagation
# Hook event: PostToolUse
#
# Purpose:
#   After a subagent writes a status file via cast_write_status, this hook reads
#   the latest file in ~/.claude/agent-status/ and acts on it:
#
#   BLOCKED           → hard-block the session (exit 2) with [CAST-HALT] directive
#   DONE_WITH_CONCERNS → inject [CAST-REVIEW] hookSpecificOutput for main session review
#   DONE / NEEDS_CONTEXT / missing file → exit 0 silently
#
# IMPORTANT — inverted subprocess guard:
#   Unlike route.sh and post-tool-hook.sh (which run in the MAIN session),
#   this hook fires inside subagent context (CLAUDE_SUBPROCESS=1).
#   We must EXIT EARLY when NOT in a subagent — the main session has no status to read.

# Inverted guard: only run inside a subagent process
if [ "${CLAUDE_SUBPROCESS:-0}" != "1" ]; then exit 0; fi

set -euo pipefail

CAST_STATUS_DIR="${CAST_STATUS_DIR:-${HOME}/.claude/agent-status}"

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
CAST_STATUS_FILE="$REAL_PATH" python3 -c "
import json, os, sys

filepath = os.environ.get('CAST_STATUS_FILE', '')
try:
    with open(filepath) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)

status    = d.get('status', '')
agent     = d.get('agent', 'unknown')
summary   = d.get('summary', '')
concerns  = d.get('concerns') or ''

if status == 'BLOCKED':
    msg = (
        f'**[CAST-HALT]** Agent \`{agent}\` is BLOCKED and cannot proceed.\n'
        f'Summary: {summary}'
    )
    if concerns:
        msg += f'\nConcerns: {concerns}'
    msg += '\nResolve the blocker before continuing. Do not retry the blocked operation.'
    print(msg)
    sys.exit(2)

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

# DONE / NEEDS_CONTEXT / unknown — exit silently
sys.exit(0)
" 2>/dev/null
STATUS_EXIT="${PIPESTATUS[0]:-$?}"

exit "$STATUS_EXIT"
