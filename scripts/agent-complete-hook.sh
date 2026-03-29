#!/bin/bash
# agent-complete-hook.sh — PostToolUse hook for Agent tool
# Emits agent_complete to routing-log.jsonl when an agent finishes.
# Also parses the agent's response for a Status block and:
#   - Writes [CAST-ESCALATE] to stderr for BLOCKED
#   - Writes [CAST-INFO] to stderr for DONE_WITH_CONCERNS
#   - Writes [CAST-WARN] to stderr when no Status block is found
#   - Writes a JSON status event to ~/.claude/cast/events/
#   - Adds a "status" field to the routing-log.jsonl entry

[ "${CLAUDE_SUBPROCESS:-0}" = "1" ] && exit 0

set -euo pipefail

HOOK_INPUT="$(cat)"

python3 - <<'PYEOF' || exit 0
import json, os, re, sys, uuid
from datetime import datetime, timezone

raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

if data.get("tool_name") != "Agent":
    sys.exit(0)

# --- Extract agent name ---
tool_input = data.get("tool_input") or {}
subagent_type = tool_input.get("subagent_type") or "unknown"
description = tool_input.get("description") or tool_input.get("prompt") or ""
preview = description[:80] if description else subagent_type[:80]

# --- Extract tool_result text ---
# tool_result may be a plain string or a dict with {"type":"tool_result","content":...}
tool_result = data.get("tool_result", "")
if isinstance(tool_result, dict):
    content = tool_result.get("content", "")
    if isinstance(content, list):
        # array of content blocks — join text blocks
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
            elif isinstance(block, str):
                parts.append(block)
        result_text = "\n".join(parts)
    elif isinstance(content, str):
        result_text = content
    else:
        result_text = str(tool_result)
elif isinstance(tool_result, str):
    result_text = tool_result
else:
    result_text = ""

# --- Parse Status block ---
# Match "Status: DONE", "Status: DONE_WITH_CONCERNS", "Status: BLOCKED", "Status: NEEDS_CONTEXT"
STATUS_PATTERN = re.compile(
    r"Status:\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)",
    re.IGNORECASE
)
match = STATUS_PATTERN.search(result_text)
if match:
    status_found = match.group(1).upper()
else:
    status_found = "missing"

# --- Stderr signals ---
if status_found == "BLOCKED":
    print(
        f"[CAST-ESCALATE] Agent {subagent_type} returned BLOCKED — human intervention required",
        file=sys.stderr
    )
elif status_found == "DONE_WITH_CONCERNS":
    print(
        f"[CAST-INFO] Agent {subagent_type} returned DONE_WITH_CONCERNS — review recommended",
        file=sys.stderr
    )
elif status_found == "missing":
    print(
        f"[CAST-WARN] Agent {subagent_type} returned without a Status block — may have failed silently",
        file=sys.stderr
    )

# --- Write status event to ~/.claude/cast/events/ ---
now = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
events_dir = os.path.expanduser("~/.claude/cast/events")
os.makedirs(events_dir, exist_ok=True)

event = {
    "id": str(uuid.uuid4()),
    "timestamp": iso_ts,
    "type": "agent_status",
    "agent": subagent_type,
    "status": status_found,
    "prompt_preview": preview,
}
# Filename: <ISO-timestamp>-<agent>-status.json (sanitize agent name for filesystem safety)
safe_agent = re.sub(r"[^a-zA-Z0-9_-]", "_", subagent_type)
short_id = str(uuid.uuid4())[:8]
event_filename = f"{iso_ts}-{short_id}-{safe_agent}-status.json"
event_path = os.path.join(events_dir, event_filename)
try:
    with open(event_path, "w") as ef:
        json.dump(event, ef, indent=2)
        ef.write("\n")
except Exception as e:
    print(f"[CAST-WARN] agent-complete-hook: failed to write event file: {e}", file=sys.stderr)

# --- Append to routing-log.jsonl (with status field) ---
entry = {
    "timestamp": iso_ts,
    "action": "agent_complete",
    "matched_route": subagent_type,
    "agent_name": subagent_type,
    "prompt_preview": preview,
    "command": None,
    "pattern": "Agent tool",
    "confidence": "hard",
    "status": status_found,
}

log_path = os.path.expanduser("~/.claude/routing-log.jsonl")
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception as e:
    print(f"[CAST-WARN] agent-complete-hook: failed to write routing log: {e}", file=sys.stderr)

PYEOF

exit 0
