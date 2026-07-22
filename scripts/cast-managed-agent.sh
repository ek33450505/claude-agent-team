#!/usr/bin/env bash
# cast-managed-agent.sh — dispatch a task via Anthropic Managed Agents
# Usage:
#   cast-managed-agent.sh <agent-name> <prompt> [--local-fallback] [--define-only] [--fork] [--no-stream]
# Flags:
#   --local-fallback   fall back to local dispatch on Managed Agents API errors
#   --define-only      stop after agent definition (do not create environment/session)
#   --fork             export CLAUDE_CODE_FORK_SUBAGENT=1 in agent environment
#   --no-stream        disable SSE streaming (use synchronous polling; suitable for CI/non-TTY)
# Env:
#   ANTHROPIC_API_KEY                required (or stored in macOS keychain under 'anthropic-api-key')
#   CAST_MANAGED_AGENT_BETA_HEADER   optional — override the anthropic-beta header sent to the API
#                                    (default: managed-agents-2026-04-01). Use when Anthropic releases
#                                    a newer beta header generation (e.g. managed-agents-2026-XX-YY).
# Beta header: managed-agents-2026-04-01 (overridable via CAST_MANAGED_AGENT_BETA_HEADER)
set -euo pipefail
# Disable xtrace globally — this script handles ANTHROPIC_API_KEY and must never echo it
set +x

# --- Subprocess bypass ---
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# --- Constants ---
BETA_HEADER="${CAST_MANAGED_AGENT_BETA_HEADER:-managed-agents-2026-04-01}"
API_BASE="${ANTHROPIC_API_BASE:-https://api.anthropic.com}"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/managed-agent-invocations.log"

# --- Parse args ---
AGENT_NAME=""
PROMPT=""
LOCAL_FALLBACK=0
DEFINE_ONLY=0
FORK_MODE=0
NO_STREAM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-fallback) LOCAL_FALLBACK=1; shift ;;
    --define-only) DEFINE_ONLY=1; shift ;;
    --fork) FORK_MODE=1; shift ;;
    --no-stream) NO_STREAM=1; shift ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -z "${AGENT_NAME}" ]]; then
        AGENT_NAME="$1"
      elif [[ -z "${PROMPT}" ]]; then
        PROMPT="$1"
      else
        echo "Too many args" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$AGENT_NAME" || -z "$PROMPT" ]]; then
  echo "Usage: cast-managed-agent.sh <agent-name> <prompt> [--local-fallback] [--define-only] [--fork] [--no-stream]" >&2
  exit 2
fi

# --- Verify API key (env var, then macOS Keychain fallback) ---
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  # Try macOS Keychain fallback
  if command -v security >/dev/null 2>&1; then
    KEYCHAIN_KEY="$(security find-generic-password -s anthropic-api-key -w 2>/dev/null || true)"
    if [[ -n "$KEYCHAIN_KEY" ]]; then
      ANTHROPIC_API_KEY="$KEYCHAIN_KEY"
      export ANTHROPIC_API_KEY
    fi
  fi
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY not set (env var or keychain)" >&2
  exit 2
fi

# --- Logging setup ---
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
_log() {
  local status="$1"
  local msg="${2:-}"
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') agent=${AGENT_NAME} prompt_len=${#PROMPT} status=${status}${msg:+ msg=${msg}}" >> "$LOG_FILE"
}

_log "invoked"

# --- Mode label for telemetry ---
if [[ "$DEFINE_ONLY" -eq 1 ]]; then
  MODE_LABEL="define-only"
else
  MODE_LABEL="full-session"
fi

# --- Export fork mode if requested ---
if [[ "$FORK_MODE" -eq 1 ]]; then
  export CLAUDE_CODE_FORK_SUBAGENT=1
fi

# --- Telemetry helper ---
# Usage: _write_telemetry <mode> <http_status> <exit_code> <duration_ms>
# Uses a quoted heredoc so shell does NOT interpolate inside Python source.
# All dynamic values are passed via env vars read by os.environ.get().
_write_telemetry() {
  local mode="$1" http_status="$2" exit_code="$3" duration_ms="$4"
  CAST_MA_AGENT_NAME="${AGENT_NAME:-}" \
  CAST_MA_MODE="$mode" \
  CAST_MA_HTTP_STATUS="$http_status" \
  CAST_MA_EXIT_CODE="$exit_code" \
  CAST_MA_DURATION_MS="$duration_ms" \
  python3 - <<'PYTELEMETRY' 2>/dev/null || true
import sys, os
sys.path.insert(0, os.path.expanduser('~/Projects/personal/claude-agent-team/scripts'))
sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
try:
    from cast_db import db_execute, db_write
    import datetime
    db_execute('''
        CREATE TABLE IF NOT EXISTS managed_agent_invocations (
            id TEXT PRIMARY KEY,
            ts TEXT,
            agent_name TEXT,
            mode TEXT,
            http_status INTEGER,
            exit_code INTEGER,
            session_duration_ms INTEGER
        )
    ''')
    db_write('managed_agent_invocations', {
        'id': os.urandom(8).hex(),
        'ts': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'agent_name': os.environ.get('CAST_MA_AGENT_NAME', ''),
        'mode': os.environ.get('CAST_MA_MODE', ''),
        'http_status': int(os.environ.get('CAST_MA_HTTP_STATUS', '0') or 0),
        'exit_code': int(os.environ.get('CAST_MA_EXIT_CODE', '0') or 0),
        'session_duration_ms': int(os.environ.get('CAST_MA_DURATION_MS', '0') or 0),
    })
except Exception:
    pass
PYTELEMETRY
}

# --- Helper: make one curl step ---
# Usage: _curl_step <method> <url> <request_body_json>
# Prints response body to stdout; sets LAST_HTTP_STATUS in caller's scope
_curl_step() {
  local method="$1"
  local url="$2"
  local body="$3"

  local raw_response=""
  local curl_exit=0

  raw_response="$(echo "$body" | curl \
    --silent \
    --show-error \
    --fail-with-body \
    --max-redirs 3 \
    -X "$method" "$url" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-beta: ${BETA_HEADER}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    --data-binary @- \
    --write-out "\n__HTTP_STATUS__%{http_code}" 2>&1)" || curl_exit=$?

  local http_status=""
  local response_body=""
  if [[ "$raw_response" =~ __HTTP_STATUS__([0-9]+)$ ]]; then
    http_status="${BASH_REMATCH[1]}"
    response_body="${raw_response%__HTTP_STATUS__*}"
  else
    response_body="$raw_response"
  fi

  # Export for telemetry
  LAST_HTTP_STATUS="$http_status"

  # Auth errors: always fail-closed regardless of --local-fallback
  if [[ "$http_status" == "401" || "$http_status" == "403" ]]; then
    _log "auth_error" "http=${http_status}"
    echo "ERROR: authentication failure (HTTP ${http_status})" >&2
    return 1
  fi

  if [[ "$curl_exit" -ne 0 ]]; then
    local truncated="${response_body:0:200}"
    _log "error" "http=${http_status}"
    if [[ "$LOCAL_FALLBACK" -eq 1 ]]; then
      echo "WARN: Managed Agents call failed (HTTP ${http_status}), falling back to local dispatch" >&2
      return 2
    else
      echo "ERROR: Managed Agents API call failed (HTTP ${http_status}): ${truncated}" >&2
      return 1
    fi
  fi

  echo "$response_body"
  return 0
}

# --- Build agent definition request body ---
DEFINE_BODY="$(CAST_MA_PROMPT="$PROMPT" CAST_MA_AGENT="$AGENT_NAME" python3 -c '
import json, os
name = os.environ["CAST_MA_AGENT"]
prompt = os.environ["CAST_MA_PROMPT"]
body = {
    "name": name,
    "model": os.environ.get("CAST_MANAGED_AGENT_MODEL", "claude-haiku-4-5"),
    "system": prompt,
    "tools": [{"type": "agent_toolset_20260401"}]
}
print(json.dumps(body))
')"

# --- Step 1: POST /v1/agents ---
LAST_HTTP_STATUS="0"
STEP1_RESPONSE=""
STEP1_RESPONSE="$(_curl_step POST "${API_BASE}/v1/agents" "$DEFINE_BODY")" || {
  local_exit=$?
  if [[ "$local_exit" -eq 2 ]]; then
    # local-fallback path
    LAST_HTTP_STATUS="${LAST_HTTP_STATUS:-0}"
    _write_telemetry "$MODE_LABEL" "${LAST_HTTP_STATUS:-0}" 0 0
    exit 0
  fi
  _write_telemetry "$MODE_LABEL" "${LAST_HTTP_STATUS:-0}" 1 0
  exit 1
}

STEP1_HTTP_STATUS="$LAST_HTTP_STATUS"
_log "agent_defined" "http=${STEP1_HTTP_STATUS}"

# Extract agent_id
AGENT_ID="$(echo "$STEP1_RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"

if [[ -z "$AGENT_ID" ]]; then
  _log "error" "agent_id missing from Step 1 response"
  echo "ERROR: agent definition response missing required field: id" >&2
  _write_telemetry "$MODE_LABEL" "${LAST_HTTP_STATUS:-0}" 1 0
  exit 1
fi

# --define-only: stop here, emit response, done
if [[ "$DEFINE_ONLY" -eq 1 ]]; then
  echo "$STEP1_RESPONSE"
  _write_telemetry "define-only" "${STEP1_HTTP_STATUS:-0}" 0 0
  exit 0
fi

# --- Step 2: POST /v1/environments ---
ENV_BODY="$(CAST_MA_AGENT_ID="$AGENT_ID" python3 -c '
import json, os
body = {
    "agent_id": os.environ["CAST_MA_AGENT_ID"],
    "type": "default"
}
print(json.dumps(body))
')"

LAST_HTTP_STATUS="0"
STEP2_RESPONSE=""
STEP2_RESPONSE="$(_curl_step POST "${API_BASE}/v1/environments" "$ENV_BODY")" || {
  local_exit=$?
  if [[ "$local_exit" -eq 2 ]]; then
    exit 0
  fi
  exit 1
}

STEP2_HTTP_STATUS="$LAST_HTTP_STATUS"
_log "environment_created" "http=${STEP2_HTTP_STATUS}"

# Extract environment_id
ENVIRONMENT_ID="$(echo "$STEP2_RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"

if [[ -z "$ENVIRONMENT_ID" ]]; then
  _log "error" "environment_id missing from Step 2 response"
  echo "ERROR: environment creation response missing required field: id" >&2
  _write_telemetry "$MODE_LABEL" "${LAST_HTTP_STATUS:-0}" 1 0
  exit 1
fi

# --- agent_runs telemetry helper (Task 2.3) ---
# Usage: _write_agent_runs <status>
# All dynamic values passed via env vars — single-quoted heredoc is CRITICAL.
# task_summary dropped from agent_runs in migration 024 (wave-3 inc3 — 100% NULL).
_write_agent_runs() {
  local run_status="$1"
  CAST_AGENT_NAME="${AGENT_NAME}" \
  CAST_STARTED_AT="${SESSION_STARTED_AT:-}" \
  CAST_AGENT_STATUS="$run_status" \
  python3 - <<'PYEOF' 2>/dev/null || true
import sys, os, datetime
sys.path.insert(0, os.path.expanduser('~/Projects/personal/claude-agent-team/scripts'))
sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
try:
    from cast_db import db_execute, db_write
    db_execute('''
        CREATE TABLE IF NOT EXISTS agent_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            agent TEXT NOT NULL,
            model TEXT,
            started_at TEXT,
            ended_at TEXT,
            status TEXT,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cost_usd REAL,
            execution_mode TEXT DEFAULT 'local'
        )
    ''')
    db_write('agent_runs', {
        'session_id': os.environ.get('CAST_SESSION_ID') or None,   # NULL > '' to avoid FK orphans
        'agent': os.environ.get('CAST_AGENT_NAME', 'unknown'),
        'started_at': os.environ.get('CAST_STARTED_AT', ''),
        'ended_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'status': os.environ.get('CAST_AGENT_STATUS', 'unknown'),
        'execution_mode': 'managed',
    })
except Exception:
    pass
PYEOF
}

# --- SSE parser helper (Task 2.2) ---
# Usage: _parse_sse_output <raw_sse_text>
# Prints extracted text deltas to stdout, returns accumulated text.
_parse_sse_lines() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "data: [DONE]" ]]; then
      continue
    fi
    if [[ "$line" == data:* ]]; then
      local payload="${line#data: }"
      # Extract text delta if present; fall back to printing raw payload
      local text
      text="$(echo "$payload" | python3 -c '
import json, sys
try:
    obj = json.load(sys.stdin)
    delta = obj.get("delta", {})
    t = delta.get("text", "")
    if t:
        print(t, end="")
except Exception:
    pass
' 2>/dev/null || true)"
      printf '%s' "$text"
    fi
  done
}

# --- Step 3: POST /v1/sessions ---
SESSION_BODY="$(CAST_MA_AGENT_ID="$AGENT_ID" CAST_MA_ENV_ID="$ENVIRONMENT_ID" CAST_MA_AGENT="$AGENT_NAME" python3 -c '
import json, os
body = {
    "agent_id": os.environ["CAST_MA_AGENT_ID"],
    "environment_id": os.environ["CAST_MA_ENV_ID"],
    "title": os.environ["CAST_MA_AGENT"] + " session"
}
print(json.dumps(body))
')"

# Single cold start for both session-start values instead of two separate
# python3 invocations (tab-separated read, mirrors cast-subagent-start-hook.sh).
IFS=$'\t' read -r SESSION_START_MS SESSION_STARTED_AT <<<"$(python3 -c '
import time, datetime
ms = int(time.time() * 1000)
iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(f"{ms}\t{iso}")
')"
LAST_HTTP_STATUS="0"
STEP3_RESPONSE=""
STEP3_AGENT_OUTPUT=""

if [[ "$NO_STREAM" -eq 1 ]]; then
  # --- Non-streaming (polling) path ---
  STEP3_RESPONSE="$(_curl_step POST "${API_BASE}/v1/sessions" "$SESSION_BODY")" || {
    local_exit=$?
    if [[ "$local_exit" -eq 2 ]]; then
      _write_agent_runs "fallback" ""
      exit 0
    fi
    _write_agent_runs "error" ""
    _write_telemetry "$MODE_LABEL" "${LAST_HTTP_STATUS:-0}" 1 0
    exit 1
  }
  SESSION_END_MS="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  SESSION_DURATION_MS=$(( SESSION_END_MS - SESSION_START_MS ))
  STEP3_HTTP_STATUS="$LAST_HTTP_STATUS"
  _log "success" "http=${STEP3_HTTP_STATUS} duration_ms=${SESSION_DURATION_MS}"
  echo "$STEP3_RESPONSE"
  STEP3_AGENT_OUTPUT="$STEP3_RESPONSE"
else
  # --- SSE streaming path ---
  # Use --no-buffer to get progressive output; accumulate lines for cast.db write.
  curl_sse_exit=0
  sse_tmpfile="$(mktemp)"

  echo "$SESSION_BODY" | curl \
    --no-buffer \
    --silent \
    --show-error \
    --max-redirs 3 \
    -X POST "${API_BASE}/v1/sessions" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-beta: ${BETA_HEADER}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -H "Accept: text/event-stream" \
    --data-binary @- \
    --write-out "\n__HTTP_STATUS__%{http_code}" \
    2>&1 | tee "$sse_tmpfile" | _parse_sse_lines || curl_sse_exit=$?

  SESSION_END_MS="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  SESSION_DURATION_MS=$(( SESSION_END_MS - SESSION_START_MS ))

  raw_sse="$(cat "$sse_tmpfile")"
  rm -f "$sse_tmpfile"

  # Extract HTTP status from appended marker
  STEP3_HTTP_STATUS="0"
  if [[ "$raw_sse" =~ __HTTP_STATUS__([0-9]+)$ ]]; then
    STEP3_HTTP_STATUS="${BASH_REMATCH[1]}"
  fi
  LAST_HTTP_STATUS="$STEP3_HTTP_STATUS"

  if [[ "$STEP3_HTTP_STATUS" == "401" || "$STEP3_HTTP_STATUS" == "403" ]]; then
    _log "auth_error" "http=${STEP3_HTTP_STATUS}"
    echo "ERROR: authentication failure (HTTP ${STEP3_HTTP_STATUS})" >&2
    _write_agent_runs "error" ""
    _write_telemetry "$MODE_LABEL" "${STEP3_HTTP_STATUS:-0}" 1 "${SESSION_DURATION_MS:-0}"
    exit 1
  fi

  if [[ "$curl_sse_exit" -ne 0 ]]; then
    if [[ "$LOCAL_FALLBACK" -eq 1 ]]; then
      _log "error" "sse_failed http=${STEP3_HTTP_STATUS} fallback=local"
      echo "WARN: Managed Agents SSE failed (HTTP ${STEP3_HTTP_STATUS}), falling back" >&2
      _write_agent_runs "fallback" ""
      _write_telemetry "$MODE_LABEL" "${STEP3_HTTP_STATUS:-0}" 0 "${SESSION_DURATION_MS:-0}"
      exit 0
    fi
    _log "error" "sse_failed http=${STEP3_HTTP_STATUS}"
    echo "ERROR: Managed Agents SSE failed (HTTP ${STEP3_HTTP_STATUS})" >&2
    _write_agent_runs "error" ""
    _write_telemetry "$MODE_LABEL" "${STEP3_HTTP_STATUS:-0}" 1 "${SESSION_DURATION_MS:-0}"
    exit 1
  fi

  # Accumulate full agent output for telemetry summary
  STEP3_AGENT_OUTPUT="$raw_sse"
  _log "success" "http=${STEP3_HTTP_STATUS} duration_ms=${SESSION_DURATION_MS} streaming=true"
  # Emit the raw session response body to stdout (parallel to the non-streaming path's
  # `echo "$STEP3_RESPONSE"`). In real SSE usage _parse_sse_lines already streamed
  # text deltas live; this ensures callers always receive something on success
  # regardless of whether the response contained SSE text-delta events.
  echo "${STEP3_AGENT_OUTPUT%%__HTTP_STATUS__*}"
fi

# --- cast.db: agent_runs (Task 2.3) ---
# Extract a brief task summary from the agent output (first 500 chars of text content)
TASK_SUMMARY="$(echo "$STEP3_AGENT_OUTPUT" | python3 -c '
import sys
raw = sys.stdin.read()
# Try to extract text from SSE lines
lines = raw.split("\n")
parts = []
for line in lines:
    line = line.strip()
    if not line.startswith("data:"):
        continue
    payload = line[5:].strip()
    if payload == "[DONE]":
        continue
    try:
        import json
        obj = json.loads(payload)
        t = obj.get("delta", {}).get("text", "")
        if t:
            parts.append(t)
    except Exception:
        pass
summary = "".join(parts)[:500]
if not summary:
    summary = raw[:500]
print(summary)
' 2>/dev/null || echo "")"

_write_agent_runs "DONE" "$TASK_SUMMARY"

# --- cast.db: managed_agent_invocations ---
_write_telemetry "$MODE_LABEL" "${STEP3_HTTP_STATUS:-0}" 0 "${SESSION_DURATION_MS:-0}"
