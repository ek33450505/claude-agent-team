#!/bin/bash
# cast-model-switch-hook.sh — PostModelSwitch hook (Claude Code >= 2.1.251)
#
# Records each session model switch as a `model_switch` row in cast.db routing_events.
# Logging-only / fail-open / async. PostModelSwitch cannot block ("the model has already
# changed") and anything printed to stdout is injected into the next request, so this
# hook prints NOTHING to stdout and always exits 0.
#
# Payload fields per code.claude.com/docs/en/hooks PostModelSwitch (docs fetched 2026-11-20;
#   live async/stdout behaviour not yet observed):
#   session_id, transcript_path, cwd, hook_event_name,
#   from_model, to_model, requested_model (null when source=auto),
#   source (command|picker|sdk|auto|resume), context_tokens, prompt_cache_warm,
#   cache_ttl (5m|1h), estimated_cache_write_usd, pricing (configured|catalog|default)
#   Payloads over ~128 KiB exceed Linux's per-string env limit and are dropped (fail-open, no row).
#
# Writes to: cast.db routing_events (existing table; no schema change). Never creates the DB.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set +e

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

set -euo pipefail

# shellcheck source=cast-sqlite-lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Existence-checked before sourcing — see cast-guard-lib.sh header (bash 3.2 + set -e
# makes `source` of a missing file fatal even left-of-`||`).
if [[ -f "${SCRIPT_DIR}/cast-sqlite-lib.sh" ]]; then
  source "${SCRIPT_DIR}/cast-sqlite-lib.sh" 2>/dev/null || true
fi
# shellcheck source=cast-hook-lib.sh
if [[ -f "${SCRIPT_DIR}/cast-hook-lib.sh" ]]; then
  source "${SCRIPT_DIR}/cast-hook-lib.sh" 2>/dev/null || true
fi

cast_hook_read_stdin
cast_hook_db_path

DB_PATH_VAL="$DB_PATH" python3 -I - 3< <(printf '%s' "$INPUT") <<'PYEOF' || _log_error "model_switch row not recorded (insert failed)"
import json, os, sqlite3, sys
from datetime import datetime, timezone

def _read_payload():
    # Payload arrives on fd 3 (an env var would hit Linux's 128 KiB per-string limit: E2BIG).
    try:
        with os.fdopen(3, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""
raw = _read_payload(); db_path = os.environ.get("DB_PATH_VAL", "")
try: data = json.loads(raw)
except Exception: sys.exit(0)
if not isinstance(data, dict): sys.exit(0)

def cap(v):
    return v[:200] if isinstance(v, str) else v

def s(v):
    # Coerce to str so a dict/list/int field can never make the sqlite bind raise.
    return v if isinstance(v, str) else ("" if v is None else json.dumps(v))

to_model = s(data.get("to_model"))
if not to_model: sys.exit(0)
if not db_path or not os.path.isfile(db_path): sys.exit(0)

session_id = cap(s(data.get("session_id")) or "unknown")
source = cap(s(data.get("source")))
cwd = s(data.get("cwd"))
project = cap(os.path.basename(cwd)) if cwd else ""
keys = ("from_model", "to_model", "requested_model", "source", "context_tokens",
        "prompt_cache_warm", "cache_ttl", "estimated_cache_write_usd", "pricing")
payload = {k: cap(data[k]) for k in keys if k in data}
iso_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data_json = json.dumps(payload)
if len(data_json) > 4000:
    # Never slice JSON text (would store invalid JSON); fall back to a small valid object.
    data_json = json.dumps({"truncated": True, "from_model": cap(s(data.get("from_model"))),
                            "to_model": cap(to_model), "source": source})

try:
    conn = sqlite3.connect(db_path, timeout=3); cur = conn.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='routing_events'")
    if cur.fetchone() is None: sys.exit(0)
    cur.execute("INSERT INTO routing_events (session_id, timestamp, action, matched_route, project, event_type, data) VALUES (?, ?, ?, ?, ?, 'model_switch', ?)",
                (session_id, iso_ts, source, cap(to_model), project, data_json))
    conn.commit()
    conn.close()
except Exception: sys.exit(3)
PYEOF

exit 0
