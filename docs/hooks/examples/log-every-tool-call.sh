#!/usr/bin/env bash
# log-every-tool-call.sh — PostToolUse hook: logs tool name + input to cast.db
#
# Hook event: PostToolUse
# Fires after every tool call completes. Appends a row to the tool_calls table
# in cast.db for observability and audit.
#
# Stdin JSON fields used:
#   tool_name   — name of the tool that was called (e.g. "Bash", "Write")
#   tool_input  — object with tool-specific arguments
#   session_id  — current session ID
#
# Exit codes:
#   0 — always (PostToolUse hooks must not block)

# Guard: exit immediately inside subagent subprocess context to prevent
# recursive hook loops.
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

# PostToolUse hooks must never fail loudly — a broken hook must not
# interrupt the parent session.
set +e

# Error logger: writes to hook-errors.log without itself failing
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}

# Read stdin once — Claude Code delivers the event JSON here
INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Pass data to Python via environment variable — never interpolate shell
# vars into the heredoc body (injection vector, breaks json.dumps escaping)
export CAST_TOOL_INPUT="$INPUT"

python3 - <<'PYEOF' 2>/dev/null || true
import json, os, sys
from datetime import datetime, timezone

raw = os.environ.get('CAST_TOOL_INPUT', '')
if not raw:
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

tool_name  = data.get('tool_name', 'unknown')
session_id = data.get('session_id', '')
tool_input = data.get('tool_input', {})

# Serialize the input object for storage; truncate to avoid huge rows
tool_input_str = json.dumps(tool_input)[:500] if isinstance(tool_input, dict) else ''

# Resolve cast.db path — always use CAST_DB_PATH env var with ~/.claude fallback
db_path = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))

# Import cast_db abstraction; fail silently if unavailable
scripts_dir = os.path.expanduser('~/.claude/scripts')
sys.path.insert(0, scripts_dir)
try:
    from cast_db import db_write
except ImportError:
    sys.exit(0)

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

try:
    db_write('tool_calls', {
        'tool_name':   tool_name,
        'tool_input':  tool_input_str,
        'session_id':  session_id,
        'created_at':  now,
    })
except Exception as e:
    import os as _os
    log_dir = _os.path.expanduser('~/.claude/logs')
    _os.makedirs(log_dir, exist_ok=True)
    with open(_os.path.join(log_dir, 'hook-errors.log'), 'a') as lf:
        lf.write(f'[{now}] ERROR log-every-tool-call.sh: db_write failed: {e}\n')
PYEOF

# Always exit 0 — PostToolUse hooks must never block
exit 0
