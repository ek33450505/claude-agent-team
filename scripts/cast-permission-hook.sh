#!/bin/bash
# cast-permission-hook.sh — CAST PermissionRequest hook
# Hook event: PermissionRequest
# Timeout: 3 seconds
#
# Called by Claude Code when a permission request is made.
# Reads JSON payload from stdin, applies auto-approve/deny rules,
# outputs a JSON decision to stdout.
#
# Output format:
#   {"decision": "allow", "reason": "..."}
#   {"decision": "deny",  "reason": "..."}
#
# Exit codes:
#   0 — always (must never block Claude Code from starting)

set +e

RULES_FILE="${HOME}/.claude/cast/permission-rules.json"
LOG_FILE="${HOME}/.claude/logs/permission-hook.log"
TIMESTAMP_FILE="${HOME}/.claude/cast/hook-last-fired/PermissionRequest.timestamp"

# Read stdin into variable (non-blocking read with timeout)
PAYLOAD=""
if read -t 2 -r line 2>/dev/null; then
  PAYLOAD="$line"
  # Drain any remaining lines
  while read -t 0.1 -r extra 2>/dev/null; do
    PAYLOAD="${PAYLOAD}${extra}"
  done
fi

# Use Python for JSON parsing and rule evaluation (no external deps)
python3 - "$RULES_FILE" "$LOG_FILE" "$TIMESTAMP_FILE" <<PYEOF
import json
import sys
import os
from datetime import datetime, timezone

payload_str = """${PAYLOAD}"""
rules_file  = sys.argv[1]
log_file    = sys.argv[2]
ts_file     = sys.argv[3]

# Default rules (used when permission-rules.json is absent or unreadable)
DEFAULT_RULES = {
    "auto_approve": [
        "git status", "git log", "git diff", "git branch", "git show",
        "ls", "cat ", "head ", "tail ", "wc ", "echo ", "which ", "pwd",
        "env ", "printenv", "date", "uname"
    ],
    "auto_deny": [
        "curl", "wget", "nc ", "ncat", "rm -rf", "dd if",
        "mkfs", "chmod 777", "sudo rm", "gh auth logout", "aws configure"
    ],
    "default": "allow"
}

def load_rules():
    try:
        with open(rules_file) as f:
            return json.load(f)
    except Exception:
        return DEFAULT_RULES

def log_decision(decision, tool, command_snippet):
    try:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        snippet = (command_snippet or "")[:80].replace("\n", " ")
        with open(log_file, "a") as f:
            f.write(f"{ts} {decision.upper()} {tool} {snippet}\n")
    except Exception:
        pass

def touch_timestamp():
    try:
        os.makedirs(os.path.dirname(ts_file), exist_ok=True)
        with open(ts_file, "a"):
            os.utime(ts_file, None)
    except Exception:
        pass

def decide(payload_str):
    # Handle empty or invalid input
    if not payload_str.strip():
        return {"decision": "allow", "reason": "no payload — default allow"}

    try:
        payload = json.loads(payload_str.strip())
    except json.JSONDecodeError:
        return {"decision": "allow", "reason": "invalid JSON payload — fail open"}

    tool = payload.get("tool", "")
    inp = payload.get("input", {})
    command = inp.get("command", "") if isinstance(inp, dict) else ""

    # File tools: always allow
    if tool in ("Read", "Write", "Edit", "Glob", "Grep"):
        return {"decision": "allow", "reason": f"{tool} tool — auto-approved"}

    rules = load_rules()
    auto_deny = rules.get("auto_deny", DEFAULT_RULES["auto_deny"])
    auto_approve = rules.get("auto_approve", DEFAULT_RULES["auto_approve"])
    default_decision = rules.get("default", "allow")

    if tool == "Bash" and command:
        # Check deny patterns first (security takes precedence)
        for pattern in auto_deny:
            if pattern in command:
                return {"decision": "deny", "reason": f"command matches auto-deny pattern: '{pattern}'"}
        # Check approve patterns
        for pattern in auto_approve:
            if command.startswith(pattern) or f" {pattern}" in command or command == pattern.strip():
                return {"decision": "allow", "reason": f"command matches auto-approve pattern: '{pattern}'"}
        # Fall through to default
        return {"decision": default_decision, "reason": f"no matching rule — using default ({default_decision})"}

    # Unknown tool: use default
    return {"decision": default_decision, "reason": f"unknown tool '{tool}' — using default ({default_decision})"}

result = decide(payload_str)
touch_timestamp()

# Determine tool/command for logging
try:
    p = json.loads(payload_str.strip()) if payload_str.strip() else {}
    log_tool = p.get("tool", "unknown")
    log_cmd = (p.get("input", {}) or {}).get("command", "")
except Exception:
    log_tool = "unknown"
    log_cmd = ""

log_decision(result["decision"], log_tool, log_cmd)
print(json.dumps(result))
PYEOF

exit 0
