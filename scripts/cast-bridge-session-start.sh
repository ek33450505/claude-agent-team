#!/usr/bin/env bash
# cast-bridge-session-start.sh
# Copyright 2026 Edward Kubiak
# Apache-2.0 License
#
# Fires on: CAST SessionStart hook
# Purpose: Session-start bridge (engram pipeline retired — this script is now a no-op).
#
# Always exits 0 — never blocks CAST session start.

set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGRAM_DB="${HOME}/.claude/engram.db"
IDENTITY_START="${SCRIPT_DIR}/engram-identity-start.sh"

# ── Safety wrapper ─────────────────────────────────────────────────────────
_safe_exit() {
    exit 0
}
trap _safe_exit ERR EXIT

# ── Check ENGRAM_DISABLED ──────────────────────────────────────────────────
if [[ "${ENGRAM_DISABLED:-0}" == "1" ]]; then
    exit 0
fi

# ── Check Engram is installed ──────────────────────────────────────────────
if [[ ! -f "$ENGRAM_DB" || ! -f "$IDENTITY_START" ]]; then
    # Engram not installed — skip gracefully
    exit 0
fi

# ── Delegate to engram-identity-start.sh ──────────────────────────────────
# Capture output so we can pass hookSpecificOutput back to CAST.
output=$(bash "$IDENTITY_START" 2>/dev/null) || true

# Pass through any hookSpecificOutput that Engram produced
if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
fi

exit 0
