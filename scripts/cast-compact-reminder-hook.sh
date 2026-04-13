#!/bin/bash
# cast-compact-reminder-hook.sh — PostToolUse hook: tracks tool calls per session,
# emits a hookSpecificOutput reminder at 40 calls to prompt /compact consideration.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || true
import json, os
from pathlib import Path

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

session_id = data.get("session_id", "unknown")
state_dir  = Path(os.path.expanduser("~/.claude/cast/compact-state"))
state_dir.mkdir(parents=True, exist_ok=True)
counter_file = state_dir / f"{session_id}.count"

count = 0
if counter_file.exists():
    try:
        count = int(counter_file.read_text().strip())
    except Exception:
        count = 0

count += 1
counter_file.write_text(str(count))

# Remind at 40 tool calls
THRESHOLD = 40
if count == THRESHOLD:
    reminder = {
        "hookSpecificOutput": {
            "type": "compact_reminder",
            "message": f"[CAST] {count} tool calls this session. Consider /compact before quality degrades (~70% context). Commit first.",
            "tool_calls": count
        }
    }
    print(json.dumps(reminder))
PYEOF

exit 0
