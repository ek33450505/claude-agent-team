#!/bin/bash
# cast-audit-hook.sh — CAST Phase 7f PreToolUse audit hook
#
# Intercepts every Claude Code tool call and appends an audit record to:
#   ~/.claude/logs/audit.jsonl
#
# Each JSONL line records:
#   timestamp        ISO8601 UTC
#   session_id       from $CLAUDE_SESSION_ID (set by Claude Code hook runner)
#   project          git remote origin or $CLAUDE_PROJECT_PATH basename
#   tool_name        the Claude Code tool being called
#   file_path        for Write/Edit/Read/Glob tool calls
#   command_preview  first 80 chars of Bash command (never full command)
#   command_hash     SHA256 of full Bash command (tamper detection)
#   content_hash     SHA256 of file content for Write calls
#   url              for WebFetch calls
#   query            for WebSearch/Glob/Grep calls
#   is_cloud_bound   true if the tool routes data outside the machine
#   input_hash       SHA256[:16] of full tool_input (catch-all fingerprint)
#
# This hook is OBSERVATION ONLY — it never blocks (always exit 0).
# Phase 7f-full will add PII redaction and air-gap enforcement.
#
# Installation (add to ~/.claude/settings.json):
#   "PreToolUse": [
#     {
#       "hooks": [
#         {
#           "type": "command",
#           "command": "bash ~/.claude/scripts/cast-audit-hook.sh"
#         }
#       ]
#     }
#   ]

# Audit hook must never fail loudly — a broken audit hook must not interrupt work.
set +e

AUDIT_LOG="$HOME/.claude/logs/audit.jsonl"

# Ensure log directory exists
mkdir -p "$HOME/.claude/logs" 2>/dev/null

# Read full hook input from stdin
INPUT="$(cat 2>/dev/null)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# ── Step 1: Parse tool-specific fields from JSON input ────────────────────────
# All dynamic data is passed via environment variable (never interpolated into
# Python source code) to prevent shell injection through crafted tool inputs.
export CAST_AUDIT_INPUT="$INPUT"

PARSED="$(python3 - <<'PYEOF' 2>/dev/null
import sys, json, os, hashlib

raw = os.environ.get('CAST_AUDIT_INPUT', '')
if not raw:
    print(json.dumps({"error": "no input"}))
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print(json.dumps({"error": "invalid json"}))
    sys.exit(0)

tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input", {}) or {}

result = {
    "tool_name": tool_name,
    "file_path": "",
    "command_preview": "",
    "command_hash": "",
    "content_hash": "",
    "url": "",
    "query": "",
    "is_cloud_bound": False,
}

if tool_name in ("Write", "Edit", "Read", "NotebookEdit", "NotebookRead"):
    result["file_path"] = (
        tool_input.get("file_path") or
        tool_input.get("notebook_path") or
        tool_input.get("path") or ""
    )
    # Hash file content — never store raw content in the audit log
    content = tool_input.get("content") or tool_input.get("new_string") or ""
    if content:
        result["content_hash"] = hashlib.sha256(content.encode()).hexdigest()

elif tool_name == "Bash":
    cmd = tool_input.get("command", "") or ""
    result["command_preview"] = cmd[:80].replace("\n", " ").strip()
    if cmd:
        result["command_hash"] = hashlib.sha256(cmd.encode()).hexdigest()

elif tool_name == "WebFetch":
    result["url"] = tool_input.get("url", "") or ""
    result["is_cloud_bound"] = True

elif tool_name == "WebSearch":
    result["query"] = (tool_input.get("query") or tool_input.get("q") or "")[:120]
    result["is_cloud_bound"] = True

elif tool_name == "Glob":
    result["query"] = tool_input.get("pattern", "") or ""

elif tool_name == "Grep":
    result["query"] = (tool_input.get("pattern", "") or "")[:80]
    result["file_path"] = tool_input.get("path", "") or ""

# Catch-all fingerprint of the full tool_input
input_str = json.dumps(tool_input, sort_keys=True)
result["input_hash"] = hashlib.sha256(input_str.encode()).hexdigest()[:16]

print(json.dumps(result))
PYEOF
)" || true

# Fallback if Python parsing failed
if [ -z "$PARSED" ] || echo "$PARSED" | grep -q '"error"'; then
  PARSED='{"tool_name":"unknown","is_cloud_bound":false,"input_hash":""}'
fi

# ── Step 2: Resolve project name ──────────────────────────────────────────────
PROJECT=""
if [ -n "${CLAUDE_PROJECT_PATH:-}" ]; then
  PROJECT="$(basename "$CLAUDE_PROJECT_PATH")"
else
  PROJECT="$(git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')" || true
  if [ -z "$PROJECT" ]; then
    PROJECT="$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")" || true
  fi
fi

# ── Step 3: Build JSONL record ────────────────────────────────────────────────
# All variables are exported and read inside a quoted heredoc (<<'PYEOF2') so
# that bash never interpolates them into Python source code — preventing shell
# injection via crafted $PROJECT, $SESSION_ID, or $PARSED values.
export CAST_AUDIT_PARSED="$PARSED"
export CAST_AUDIT_TIMESTAMP
CAST_AUDIT_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
  python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
export CAST_AUDIT_SESSION="${CLAUDE_SESSION_ID:-unknown}"
export CAST_AUDIT_PROJECT="$PROJECT"

RECORD="$(python3 - <<'PYEOF2' 2>/dev/null
import json, os

parsed_raw = os.environ.get('CAST_AUDIT_PARSED', '{}')
try:
    parsed = json.loads(parsed_raw)
except Exception:
    parsed = {}

record = {
    "timestamp": os.environ.get('CAST_AUDIT_TIMESTAMP', ''),
    "session_id": os.environ.get('CAST_AUDIT_SESSION', 'unknown'),
    "project": os.environ.get('CAST_AUDIT_PROJECT', ''),
}
record.update(parsed)

# Omit empty-string values to keep each log line compact
record = {k: v for k, v in record.items() if v != ""}
print(json.dumps(record, separators=(',', ':')))
PYEOF2
)" || true

# Last-resort fallback if Python fails entirely
if [ -z "$RECORD" ]; then
  RECORD="{\"timestamp\":\"${CAST_AUDIT_TIMESTAMP}\",\"session_id\":\"${CAST_AUDIT_SESSION}\",\"project\":\"${CAST_AUDIT_PROJECT}\",\"tool_name\":\"unknown\"}"
fi

# ── Step 4: Append to audit log ────────────────────────────────────────────────
# Single atomic line append — JSONL format (one JSON object per line).
echo "$RECORD" >> "$AUDIT_LOG" 2>/dev/null || true

# Never block — audit hook is observation only
exit 0
