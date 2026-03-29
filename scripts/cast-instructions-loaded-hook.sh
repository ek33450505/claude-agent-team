#!/bin/bash
# cast-instructions-loaded-hook.sh — InstructionsLoaded hook (Claude Code v2.1.69+)
# Logs active CLAUDE.md files at session start to instructions-loaded.jsonl.
# Registered with matcher: session_start — fires once per session, not on every traversal.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || true
import json, os
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

file_path   = data.get("file_path", "")
memory_type = data.get("memory_type", "")
load_reason = data.get("load_reason", "")
session_id  = data.get("session_id", "unknown")

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

entry = {
    "timestamp":   iso_ts,
    "session_id":  session_id,
    "file_path":   file_path,
    "memory_type": memory_type,
    "load_reason": load_reason,
}

log_path = os.path.expanduser("~/.claude/cast/instructions-loaded.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception:
    pass
PYEOF

exit 0
