#!/usr/bin/env bash
# cast-truncation-check.sh — SubagentStop hook (called from cast-subagent-worktree-check.sh)
#
# Detects agent responses that appear truncated: no Status block AND no JSON
# status block in the response. Non-trivial responses only (>50 chars).
# Logs to cast.db agent_truncations table. Emits stderr WARNING with resume guidance.
# Always exits 0.

[[ "${CLAUDE_SUBPROCESS:-}" == "1" ]] && exit 0

set -euo pipefail

INPUT="${CAST_INPUT:-$(cat 2>/dev/null || true)}"
export CAST_INPUT="$INPUT"

_log_error() {
  mkdir -p "$HOME/.claude/logs"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cast-truncation-check: $1" \
    >> "$HOME/.claude/logs/hook-errors.log"
}

CAST_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAST_HOOK_DIR

python3 - <<'PYEOF' || _log_error "truncation check failed"
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# ── Resolve cast_db.py ────────────────────────────────────────────────────────
# CAST_HOOK_DIR is set by bash to the real directory of this script before the
# heredoc runs. This is reliable even when python3 __file__ == '<stdin>'.
_SCRIPT_DIR = os.environ.get('CAST_HOOK_DIR', '')
_SCRIPTS_DIRS = [
    _SCRIPT_DIR,
    os.path.expanduser('~/.claude/scripts'),
]
for _d in _SCRIPTS_DIRS:
    _cast_db_path = os.path.join(_d, 'cast_db.py')
    if os.path.isfile(_cast_db_path):
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location('cast_db', _cast_db_path)
        _mod = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_mod)
        db_write = _mod.db_write
        db_execute = _mod.db_execute
        break
else:
    def db_write(table, payload):
        pass  # graceful no-op if cast_db.py not found
    def db_execute(sql, params=None):
        pass

# ── Idempotent schema migration: add partial_work_log column ─────────────────
try:
    db_execute(
        'ALTER TABLE agent_truncations ADD COLUMN partial_work_log TEXT'
    )
except Exception:
    pass  # column already exists — safe to ignore


def extract_work_log(text: str):
    """Extract text between '## Work Log' and 'Status:' (or end of string).

    Returns the extracted section as a stripped string, or None if no
    '## Work Log' heading is found in the text.
    """
    # Match ## Work Log heading (case-insensitive) followed by content up to
    # the first 'Status:' line or end of string.
    pattern = re.compile(
        r'##\s+Work\s+Log\s*\n([\s\S]*?)(?=\nStatus:|$)',
        re.IGNORECASE,
    )
    match = pattern.search(text)
    if not match:
        return None
    extracted = match.group(1).strip()
    return extracted if extracted else None


# ── Parse stdin (passed via CAST_INPUT env var) ───────────────────────────────
raw_input = os.environ.get('CAST_INPUT', '')
if not raw_input.strip():
    sys.exit(0)

try:
    data = json.loads(raw_input)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

agent_type = data.get('agent_type') or data.get('subagent_type') or 'unknown'
agent_id   = data.get('agent_id') or data.get('subagent_id') or ''
batch_id   = data.get('batch_id')
session_id = data.get('session_id') or ''
now_iso    = datetime.utcnow().isoformat() + 'Z'

# ── Extract last assistant message text ───────────────────────────────────────
response_text = ''
try:
    agent_response = data.get('agent_response') or {}
    content = agent_response.get('content') or []
    texts = [
        block.get('text', '')
        for block in content
        if isinstance(block, dict) and block.get('type') == 'text'
    ]
    response_text = '\n'.join(texts)
except Exception:
    response_text = ''

# ── Trivial response guard: skip if < 50 chars ────────────────────────────────
if len(response_text.strip()) < 50:
    sys.exit(0)

char_count = len(response_text)
last_line  = response_text[-200:] if len(response_text) > 200 else response_text

# ── Detection: prose Status block ─────────────────────────────────────────────
status_pattern = re.compile(
    r'^Status:\s*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)\b',
    re.MULTILINE | re.IGNORECASE,
)
has_status = bool(status_pattern.search(response_text))

# ── Detection: JSON fenced status block ───────────────────────────────────────
# Matches ```json status ... ``` with a "status" key set to a valid value
json_status_pattern = re.compile(
    r'```json\s+status[\s\S]*?"status"\s*:\s*"(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)"',
    re.IGNORECASE,
)
has_json = bool(json_status_pattern.search(response_text))

# ── Log and warn if response appears truncated ────────────────────────────────
if not has_status and not has_json:
    partial_work_log = extract_work_log(response_text)
    db_write('agent_truncations', {
        'session_id':       session_id,
        'agent_type':       agent_type,
        'agent_id':         agent_id,
        'batch_id':         batch_id,
        'last_line':        last_line,
        'timestamp':        now_iso,
        'char_count':       char_count,
        'has_status':       0,
        'has_json':         0,
        'partial_work_log': partial_work_log,
    })
    print(
        f'[CAST-TRUNCATED] Agent {agent_type} response appears truncated '
        f'(no Status block or JSON status). '
        f'Direct-verify state, resume via SendMessage with on-disk evidence.',
        file=sys.stderr,
    )

sys.exit(0)
PYEOF

exit 0
