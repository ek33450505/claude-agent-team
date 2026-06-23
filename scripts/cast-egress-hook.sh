#!/bin/bash
# cast-egress-hook.sh — CAST v9 A1 Egress / Privacy Sentinel PreToolUse wrapper.
#
# Thin bash shim (mirrors cast-audit-hook.sh): reads the hook payload from
# stdin and delegates ALL logic to cast-egress-sentinel.py. Registered on the
# PreToolUse matcher "mcp__.*|WebFetch|WebSearch|Bash|Read".
#
# Behavior is mode-driven (CAST_EGRESS_ENFORCEMENT env or cast-cli.json
# egress_enforcement; default = advisory = record + warn, never block).
#
# FAIL-OPEN: this hook must never interrupt work. A broken sentinel exits 0.

# CAST-internal subprocesses skip the hook (latency + consistency).
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

# Audit/egress hooks must never fail loudly.
set +e

mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

INPUT="$(cat 2>/dev/null)"
if [[ -z "$INPUT" ]]; then
  exit 0
fi

# Perf fast-path (security review M2): Read is a very high-frequency tool, but
# the sentinel only cares about Read of credential-shaped paths. If this is a
# Read whose payload contains no credential marker, exit BEFORE spawning python3.
# Cheap pure-shell grep — no second interpreter spawn. Non-Read tools always
# fall through to full classification.
case "$INPUT" in
  *'"tool_name":"Read"'*|*'"tool_name": "Read"'*)
    if ! printf '%s' "$INPUT" | grep -qiE '\.env|\.pem|\.key|\.p12|\.pfx|id_rsa|id_ed|id_dsa|id_ecdsa|\.netrc|\.npmrc|\.pypirc|/credentials|secret|token|/\.aws/'; then
      exit 0
    fi
    ;;
esac

SCRIPT_DIR="$(dirname "$0")"
SENTINEL="${SCRIPT_DIR}/cast-egress-sentinel.py"
if [[ ! -f "$SENTINEL" ]]; then
  _log_error "sentinel script missing: $SENTINEL"
  exit 0
fi

# Delegate. The sentinel emits its own hookSpecificOutput JSON on stdout and
# always exits 0 (it prefers the permissionDecision JSON form over exit 2).
printf '%s' "$INPUT" | python3 "$SENTINEL"
exit 0
