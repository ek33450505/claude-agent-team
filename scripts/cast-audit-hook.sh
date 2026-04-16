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
# PII enforcement: when redact_pii=true AND a cloud-bound tool call contains PII,
# this hook outputs {"decision":"block"} and exits 2 to prevent the call.
# Enforcement can be toggled: cast audit --redact on|off
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

if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

# Read full hook input from stdin
INPUT="$(cat 2>/dev/null)"
if [[ -z "$INPUT" ]]; then
  exit 0
fi

# Delegate all audit logic (parsing, record building, PII analysis, log write) to
# the consolidated Python script. All python3 invocations live there — one process.
SCRIPT_DIR="$(dirname "$0")"
echo "$INPUT" | python3 "${SCRIPT_DIR}/cast-audit.py"
exit $?
