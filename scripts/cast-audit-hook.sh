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

# C5: PII bypass safelist — known false-positive patterns skip enforcement
SAFELIST_PATTERNS=(
  'anthropic\.com'
  'github\.com'
  'example\.com'
  'example\.org'
  'noreply@'
  'user@example'
  '@anthropic'
  'claude\.ai'
  'docs\.anthropic'
)

# C5: ENFORCEMENT_MODE — only "strict" triggers exit 2 block. Default is advisory (log only).
ENFORCEMENT_MODE="${CAST_PII_ENFORCEMENT:-advisory}"

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

# ── Step 3b: PII Redaction (observation-only annotation) ─────────────────────
# If redact_pii=true in cast-cli.json and the call is cloud-bound:
#   - Run cast-redact.py in analyze mode
#   - Annotate the audit record with redacted=true and redacted_count=N
#   - Store the redaction map to ~/.claude/logs/redact-maps/
#   - Inject [CAST-REDACT-WARN] into hookSpecificOutput
# NOTE: This hook cannot intercept API calls — we annotate what WOULD be redacted.
# Failures are always silent (exit 0 guaranteed).
IS_CLOUD_BOUND="$(echo "$PARSED" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print('true' if d.get('is_cloud_bound') else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo 'false')"

if [ "$IS_CLOUD_BOUND" = "true" ]; then
  REDACT_ENABLED="$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.claude/config/cast-cli.json')) as f:
        cfg = json.load(f)
    print('true' if cfg.get('redact_pii') else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo 'false')"

  if [ "$REDACT_ENABLED" = "true" ]; then
    # Extract relevant text from PARSED (url, query, or command_preview)
    REDACT_TEXT="$(echo "$PARSED" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    text = d.get('url') or d.get('query') or d.get('command_preview') or ''
    print(text[:500])
except Exception:
    print('')
" 2>/dev/null || echo '')"

    if [ -n "$REDACT_TEXT" ]; then
      REDACT_SCRIPT="$HOME/.claude/scripts/cast-redact.py"
      REDACT_RESULT=""
      if [ -f "$REDACT_SCRIPT" ]; then
        REDACT_RESULT="$(python3 "$REDACT_SCRIPT" --text "$REDACT_TEXT" --mode analyze 2>/dev/null || echo '')"
      fi

      ENTITY_COUNT="$(echo "$REDACT_RESULT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('entity_count', 0))
except Exception:
    print(0)
" 2>/dev/null || echo '0')"

      if [ -n "$ENTITY_COUNT" ] && [ "$ENTITY_COUNT" -gt 0 ] 2>/dev/null; then
        # Annotate the audit record with redaction fields
        export CAST_REDACT_COUNT="$ENTITY_COUNT"
        RECORD="$(echo "$RECORD" | python3 -c "
import sys, json, os
try:
    r = json.loads(sys.stdin.read())
    r['redacted'] = True
    r['redacted_count'] = int(os.environ.get('CAST_REDACT_COUNT', 0))
    print(json.dumps(r, separators=(',', ':')))
except Exception:
    print(sys.stdin.read())
" 2>/dev/null || echo "$RECORD")"

        # Store redaction map
        mkdir -p "$HOME/.claude/logs/redact-maps" 2>/dev/null
        REDACT_MAP_FILE="$HOME/.claude/logs/redact-maps/${CAST_AUDIT_SESSION}-${CAST_AUDIT_TIMESTAMP}.json"
        export CAST_REDACT_RESULT="$REDACT_RESULT"
        export CAST_REDACT_MAP_SESSION="$CAST_AUDIT_SESSION"
        export CAST_REDACT_MAP_TS="$CAST_AUDIT_TIMESTAMP"
        python3 -c "
import json, os
try:
    result = json.loads(os.environ.get('CAST_REDACT_RESULT', '{}'))
    map_data = {
        'timestamp': os.environ.get('CAST_REDACT_MAP_TS', ''),
        'session_id': os.environ.get('CAST_REDACT_MAP_SESSION', ''),
        'entities': result.get('entities', [])
    }
    with open(os.path.expanduser('~/.claude/logs/redact-maps/' + os.environ.get('CAST_REDACT_MAP_SESSION','unknown') + '-' + os.environ.get('CAST_REDACT_MAP_TS','').replace(':','-') + '.json'), 'w') as f:
        json.dump(map_data, f)
except Exception:
    pass
" 2>/dev/null || true

        # Check enforcement mode: block if redact_pii=true, else warn only
        ENFORCE_BLOCK="$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.claude/config/cast-cli.json')) as f:
        cfg = json.load(f)
    print('true' if cfg.get('redact_pii') else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo 'false')"

        # C5: Check safelist — if matched text contains any safelist pattern, skip blocking
        SAFELIST_MATCHED=false
        for PATTERN in "${SAFELIST_PATTERNS[@]}"; do
          if echo "$REDACT_TEXT" | grep -qE "$PATTERN" 2>/dev/null; then
            SAFELIST_MATCHED=true
            break
          fi
        done

        if [ "$SAFELIST_MATCHED" = "true" ]; then
          # Safelist match — log advisory only, never block
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] PII-ADVISORY cast-audit-hook.sh: safelist match, skipping enforcement. Text preview: ${REDACT_TEXT:0:100}" >> "$HOME/.claude/logs/pii-advisory.log" 2>/dev/null || true
        elif [ "$ENFORCEMENT_MODE" = "strict" ] && [ "$ENFORCE_BLOCK" = "true" ]; then
          # C5: strict mode only — exit 2 to block
          # Append audit record before blocking so the block is logged
          echo "$RECORD" >> "$AUDIT_LOG" 2>/dev/null || true
          # Output block decision — Claude Code reads this from stdout
          python3 -c "
import json, os
n = int(os.environ.get('CAST_REDACT_COUNT', 0))
output = {
    'decision': 'block',
    'reason': f'[CAST-PII-BLOCK] {n} PII entities detected in cloud-bound tool call. Tool execution blocked. Set CAST_PII_ENFORCEMENT=advisory to disable blocking.'
}
print(json.dumps(output))
" 2>/dev/null || true
          exit 2
        else
          # Advisory mode (default): warn but allow. Log to pii-advisory.log.
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] PII-ADVISORY cast-audit-hook.sh: ${ENTITY_COUNT} entities detected (advisory mode). Text preview: ${REDACT_TEXT:0:100}" >> "$HOME/.claude/logs/pii-advisory.log" 2>/dev/null || true
          python3 -c "
import json, os
n = int(os.environ.get('CAST_REDACT_COUNT', 0))
output = {
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'additionalContext': f'[CAST-REDACT-WARN: {n} PII entities detected in cloud-bound tool call. Audit record annotated. Set CAST_PII_ENFORCEMENT=strict to enable blocking.]'
    }
}
print(json.dumps(output))
" 2>/dev/null || true
        fi
      fi
    fi
  fi
fi

# ── Step 4: Append to audit log ────────────────────────────────────────────────
# Single atomic line append — JSONL format (one JSON object per line).
echo "$RECORD" >> "$AUDIT_LOG" 2>/dev/null || true

exit 0
