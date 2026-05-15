#!/bin/bash
# cast-user-prompt-hook.sh — UserPromptSubmit hook
# Fires each time the user submits a prompt.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Log prompt metadata (never full text) to ~/.claude/cast/user-prompts.jsonl
#   3. Log to cast.db routing_events table
#
# Stdin JSON fields (UserPromptSubmit):
#   session_id — current session ID
#   prompt     — the user's raw prompt text
#
# Exit codes:
#   0 — always (never block the session — do not exit 2)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set +e

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

INPUT="$(cat 2>/dev/null || true)"

_CAST_REDACT_SCRIPT="$(dirname "$0")/cast-redact.py"
CAST_INPUT="$INPUT" _CAST_REDACT_SCRIPT="$_CAST_REDACT_SCRIPT" python3 - <<'PYEOF' || true
import json, os
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

session_id     = data.get("session_id", "unknown")
prompt_text    = data.get("prompt", "")
prompt_length  = len(prompt_text)
raw_preview    = prompt_text[:120]

# Redact PII from preview before writing to any log.
# If redaction fails, skip the DB write entirely — do not fall back to raw text.
import subprocess as _sp
_redact_script = os.environ.get("_CAST_REDACT_SCRIPT", "")
_redaction_ok = False
prompt_preview = None

if _redact_script and os.path.isfile(_redact_script):
    try:
        _result = _sp.run(
            ["python3", _redact_script],
            input=raw_preview,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if _result.returncode == 0 and _result.stdout.strip():
            _out = json.loads(_result.stdout)
            prompt_preview = _out.get("redacted_text")
            if prompt_preview is not None:
                _redaction_ok = True
    except Exception:
        pass

if not _redaction_ok:
    # Log the failure and skip both JSONL and DB writes for this prompt.
    _err_log = os.path.expanduser("~/.claude/logs/hook-errors.log")
    try:
        os.makedirs(os.path.dirname(_err_log), exist_ok=True)
        import time as _time
        _ts = __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(_err_log, 'a') as _f:
            _f.write(f"[{_ts}] ERROR cast-user-prompt-hook.sh: redaction failed — prompt dropped (session={session_id})\n")
    except Exception:
        pass
    import sys; sys.exit(0)

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# Log to user-prompts.jsonl
entry = {
    "timestamp":      iso_ts,
    "session_id":     session_id,
    "prompt_length":  prompt_length,
    "prompt_preview": prompt_preview,
}

log_path = os.path.expanduser("~/.claude/cast/user-prompts.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception:
    pass

# Log to cast.db routing_events
db_path = os.path.expanduser("~/.claude/cast.db")
prompt_preview_db = prompt_preview[:80]
project = os.path.basename(os.getcwd().rstrip('/')) or "unknown"
data_json = json.dumps({"prompt_length": prompt_length, "prompt_preview": prompt_preview})
try:
    import sqlite3 as _sqlite3
    con = _sqlite3.connect(db_path, timeout=3)
    con.execute(
        "INSERT INTO routing_events (timestamp, session_id, event_type, prompt_preview, action, project, data) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (iso_ts, session_id, "user_prompt_submit", prompt_preview_db, "user_prompt_submit", project, data_json),
    )
    con.commit()
    con.close()
except Exception:
    pass

# Memory retrieval and injection (non-fatal)
if not prompt_text or len(prompt_text.strip()) < 10:
    raise SystemExit(0)

script_dir = os.path.dirname(os.path.abspath(__file__))
router = os.path.join(script_dir, 'cast-memory-router.py')

if not os.path.isfile(router):
    raise SystemExit(0)

try:
    import subprocess as _subprocess
    result = _subprocess.run(
        ['python3', router, '--mode', 'retrieve', '--agent', 'shared',
         '--prompt', prompt_text[:500], '--top-n', '5', '--fts-only'],
        capture_output=True, text=True, timeout=5
    )
    memories = json.loads(result.stdout or '[]')
except Exception:
    memories = []

if not memories:
    raise SystemExit(0)

# Format as [memory:type:name] lines for injection
lines = []
for m in memories:
    score = m.get('score', 0)
    if score < 0.3:  # minimum relevance threshold
        continue
    mem_type = m.get('type', '')
    name = m.get('name', '')
    content = m.get('content', '')[:200]
    if mem_type and name and content:
        lines.append(f"[memory:{mem_type}:{name}] {content}")

if not lines:
    raise SystemExit(0)

context_block = "Relevant memory context:\n" + "\n".join(lines)

# Emit as additionalContext in hookSpecificOutput
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context_block
    }
}))
PYEOF

exit 0
