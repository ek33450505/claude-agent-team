#!/usr/bin/env bash
# cast-agent-protocol-check.sh — SubagentStop hook (called from cast-subagent-worktree-check.sh)
#
# Scans the agent's last assistant message for prose-only dispatch claims
# (e.g., "Dispatching code-reviewer" without an actual Agent tool call).
# Logs violations to cast.db agent_protocol_violations table.
# ALWAYS exits 0 — warn only, never block.

[[ "${CLAUDE_SUBPROCESS:-}" == "1" ]] && exit 0

set -euo pipefail

INPUT="${CAST_INPUT:-$(cat 2>/dev/null || true)}"

_log_error() {
  mkdir -p "$HOME/.claude/logs"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cast-agent-protocol-check: $1" \
    >> "$HOME/.claude/logs/hook-errors.log"
}

CAST_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAST_HOOK_DIR

# Run detection logic in Python for JSON parsing and DB access
python3 - <<'PYEOF' || _log_error "protocol check failed"
import json
import os
import re
import sys
from datetime import datetime, timezone

# Resolve cast_db.py from the real hook script directory.
# CAST_HOOK_DIR is set by bash before the heredoc; __file__ == '<stdin>' in heredocs
# so it cannot be used to locate sibling files reliably.
_REPO_DIR = os.environ.get("CAST_HOOK_DIR", "")
_SCRIPTS_DIRS = [
    _REPO_DIR,
    os.path.expanduser("~/.claude/scripts"),
]
for _d in _SCRIPTS_DIRS:
    _cast_db = os.path.join(_d, "cast_db.py")
    if os.path.isfile(_cast_db):
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location("cast_db", _cast_db)
        cast_db = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(cast_db)
        db_write = cast_db.db_write
        break
else:
    def db_write(table, payload):
        pass  # graceful no-op if cast_db.py not found

raw_input = os.environ.get("CAST_INPUT", "")
if not raw_input:
    sys.exit(0)

try:
    data = json.loads(raw_input)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

agent_type  = data.get("agent_type") or data.get("subagent_type") or "unknown"
agent_id    = data.get("agent_id") or data.get("subagent_id") or ""
batch_id    = data.get("batch_id")
session_id  = data.get("session_id") or ""

# Extract the agent's message text. Real SubagentStop payloads use the flat
# last_assistant_message/output fields (same as cast-subagent-stop-hook.sh);
# agent_response.content[] is supported as a fallback.
agent_response = data.get("agent_response") or {}
content_blocks = agent_response.get("content") or []

text_parts = []
has_tool_use = False
for block in content_blocks:
    if isinstance(block, dict):
        if block.get("type") == "text":
            text_parts.append(block.get("text") or "")
        elif block.get("type") == "tool_use":
            has_tool_use = True

# Flat-field message text — the format the harness actually sends.
flat_text = data.get("last_assistant_message") or data.get("output") or data.get("response_text") or data.get("body") or ""
if flat_text:
    text_parts.append(flat_text)

full_text = "\n".join(p for p in text_parts if p)

# Detect real tool use from the flat payload too: a non-empty tool_uses list or a
# positive tool_use_count means the agent actually called tools (not all-talk).
tool_uses = data.get("tool_uses")
if isinstance(tool_uses, list) and tool_uses:
    has_tool_use = True
if (data.get("tool_use_count") or 0) > 0:
    has_tool_use = True

# Belt-and-suspenders: tool_use markers anywhere in the raw payload.
if '"type": "tool_use"' in raw_input or '"type":"tool_use"' in raw_input:
    has_tool_use = True

if not full_text:
    sys.exit(0)

# Line-anchored prose-dispatch patterns (case-insensitive).
# Only matches at the START of a line to avoid incidental mentions.
PROSE_PATTERNS = re.compile(
    r'^(dispatching|i\'ll dispatch|i will dispatch|will dispatch)\s+.+',
    re.IGNORECASE | re.MULTILINE
)

# Skip lines that are inside fenced code blocks (``` ... ```)
def strip_code_blocks(text):
    """Remove content between triple-backtick fences."""
    return re.sub(r'```.*?```', '', text, flags=re.DOTALL)

clean_text = strip_code_blocks(full_text)

match = PROSE_PATTERNS.search(clean_text)

if match and not has_tool_use:
    # Extract a short excerpt around the match
    start = max(0, match.start() - 40)
    end = min(len(clean_text), match.end() + 80)
    excerpt = clean_text[start:end].strip()

    matched_pattern = match.group(0).strip()[:120]  # cap to 120 chars

    now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

    payload = {
        "session_id":  session_id,
        "agent_type":  agent_type,
        "agent_id":    agent_id,
        "batch_id":    batch_id,
        "violation":   "prose_dispatch",
        "pattern":     matched_pattern,
        "timestamp":   now_iso,
        "raw_excerpt": excerpt[:500],
    }
    # Remove None values to avoid SQLite type issues
    payload = {k: v for k, v in payload.items() if v is not None}

    try:
        db_write("agent_protocol_violations", payload)
    except Exception as e:
        pass  # never crash the hook pipeline

    print(
        f"[CAST-PROTOCOL] Agent {agent_type} appears to have paraphrased dispatch of "
        f"'{matched_pattern}' without an Agent tool call",
        file=sys.stderr
    )
    print(
        f"[CAST-WARN] agent_protocol_violations: {agent_type} paraphrased dispatch — "
        f"logged to cast.db",
        file=sys.stderr
    )

sys.exit(0)
PYEOF

exit 0
