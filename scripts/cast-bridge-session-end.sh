#!/usr/bin/env bash
# cast-bridge-session-end.sh
# Copyright 2026 Edward Kubiak
# Apache-2.0 License
#
# Fires on: CAST Stop (session-end) hook
# Purpose: Thin bridge that:
#   1. Reads CAST_SESSION_TRANSCRIPT env var (set by CAST's Stop hook)
#   2. Pipes transcript to engram-session-end.sh for signal extraction
#   3. Runs engram compress to dedup signals after extraction
#   Respects ENGRAM_DISABLED=1 to skip processing.
#
# Always exits 0 — never blocks CAST session end.

set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENGRAM_DB="${HOME}/.claude/engram.db"
SESSION_END="${SCRIPT_DIR}/engram-session-end.sh"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/cast-bridge-session-end.log"

# ── Safety wrapper ─────────────────────────────────────────────────────────
_safe_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        mkdir -p "${LOG_DIR}"
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') cast-bridge-session-end.sh exited with code ${exit_code}" \
            >> "${LOG_FILE}" 2>/dev/null || true
    fi
    exit 0
}
trap _safe_exit ERR EXIT

# ── Check ENGRAM_DISABLED ──────────────────────────────────────────────────
if [[ "${ENGRAM_DISABLED:-0}" == "1" ]]; then
    exit 0
fi

# ── Check Engram is installed ──────────────────────────────────────────────
if [[ ! -f "$ENGRAM_DB" || ! -f "$SESSION_END" ]]; then
    # Engram not installed — skip gracefully
    exit 0
fi

# ── Locate Python ─────────────────────────────────────────────────────────
PYTHON="${REPO_DIR}/.venv/bin/python3"
if [[ ! -f "$PYTHON" ]]; then
    PYTHON="python3"
fi

# ── Step 1: Pass transcript to extraction pipeline ─────────────────────────
# CAST_SESSION_TRANSCRIPT is set by CAST's Stop hook when a transcript is available.
if [[ -n "${CAST_SESSION_TRANSCRIPT:-}" ]]; then
    # Write transcript to a temp file for engram-session-end.sh to process
    TRANSCRIPT_TMP="$(mktemp)"
    printf '%s' "$CAST_SESSION_TRANSCRIPT" > "$TRANSCRIPT_TMP"
    export ENGRAM_TRANSCRIPT_PATH="${TRANSCRIPT_TMP}"

    # Delegate to engram-session-end.sh (handles journal extraction + session bump)
    bash "$SESSION_END" 2>/dev/null || true

    rm -f "$TRANSCRIPT_TMP"
else
    # No transcript — still run session end for journal processing + session count
    bash "$SESSION_END" 2>/dev/null || true
fi

# ── Step 2: Run compress to dedup signals ─────────────────────────────────
if [[ -f "$ENGRAM_DB" ]]; then
    "$PYTHON" "${REPO_DIR}/src/cli.py" compress --db-path "$ENGRAM_DB" \
        2>/dev/null || true
fi

exit 0
