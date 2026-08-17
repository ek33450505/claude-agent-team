#!/bin/bash
# cast-audit-hook.sh — CAST audit hook (PreToolUse block path + PostToolUse log path)
#
# Usage:
#   cast-audit-hook.sh [--mode pre|post]
#
#   --mode pre  (default) PreToolUse path: can exit 2 to block cloud-bound PII calls.
#               Register with matcher "WebFetch|WebSearch", synchronous, timeout 5.
#   --mode post PostToolUse path: audit-log-only, never exits 2.
#               Register with async: true (no matcher), timeout 3.
#
# Appends an audit record to ~/.claude/logs/audit.jsonl for every invocation.
#
# Each JSONL line records:
#   timestamp        ISO8601 UTC
#   session_id       from the hook payload's session_id key, falling back to
#                    $CLAUDE_SESSION_ID, then "unknown"
#   project          CLAUDE_PROJECT_DIR basename or git toplevel
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
#   MCP tool calls (tool_name starts with "mcp__") additionally record:
#     mcp_server       server name split from mcp__<server>__<tool>
#     mcp_tool         tool name split from mcp__<server>__<tool>
#     args_summary     key:type(len) shape only — NEVER argument values
#     outcome          "ok" or "error", derived from tool_response
#     error_preview    first 120 chars of a REDACTED error (error outcomes
#                      only; sanitized via cast-redact.py before truncation,
#                      dropped entirely — not stored raw — if sanitization
#                      fails)
#     result_size      byte length of the JSON-serialized tool_response
#   MCP calls are also persisted to cast.db routing_events
#   (event_type='mcp_tool_call') since audit.jsonl rotates out in ~12 days.
#
# PII enforcement (pre mode only): when redact_pii=true AND a cloud-bound tool
# call contains PII, exits 2 to block the call.
# Toggle: cast audit --redact on|off

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
# Pass --mode through if supplied as argument to this script.
SCRIPT_DIR="$(dirname "$0")"
AUDIT_MODE="pre"
for arg in "$@"; do
  if [[ "$arg" == "--mode" ]]; then
    shift_next=1
  elif [[ "${shift_next:-0}" == "1" ]]; then
    AUDIT_MODE="$arg"
    shift_next=0
  fi
done
echo "$INPUT" | python3 "${SCRIPT_DIR}/cast-audit.py" --mode "$AUDIT_MODE"
exit $?
