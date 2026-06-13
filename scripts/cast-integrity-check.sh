#!/usr/bin/env bash
# cast-integrity-check.sh — Daily regression-aware integrity check wrapper
#
# Entry point for the daily launchd job (com.cast.integrity).
# Runs as the user (not as a Claude Code agent).
#
# Behaviour:
#   1. Runs `cast integrity` and captures output.
#   2. Appends a timestamped block to the audit log (always).
#   3. On FIRST run: writes the warn count as the baseline silently (no notification).
#   4. On subsequent runs: fires a desktop notification ONLY when the warn count
#      RISES above the stored baseline (regression-aware — standing WARNs like the
#      known O5 colocated-backup defer do NOT nag every day).
#   5. Always updates the baseline file (both on increase and decrease).
#
# Env overrides (for tests):
#   CAST_INTEGRITY_LOG   Override the audit log path
#   CAST_INTEGRITY_BASELINE  Override the baseline state-file path
#
# Exit codes: always 0 (daemon-style; the log carries the real status).

# ── Subprocess guard (must come before set -euo pipefail) ─────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
LOGS_DIR="${HOME}/.claude/logs"
BASELINE_DIR="${HOME}/.claude/cast"

LOG_FILE="${CAST_INTEGRITY_LOG:-${LOGS_DIR}/cast-integrity-check.log}"
BASELINE_FILE="${CAST_INTEGRITY_BASELINE:-${BASELINE_DIR}/integrity-warn-baseline}"

mkdir -p "${LOGS_DIR}" "${BASELINE_DIR}"

# ── Timestamp helper ──────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Resolve the cast binary ───────────────────────────────────────────────────
# launchd has a minimal PATH; probe expected locations before giving up.
CAST_BIN="$(command -v cast 2>/dev/null || true)"
if [ -z "${CAST_BIN}" ]; then
  CAST_BIN="${HOME}/.local/bin/cast"
fi

if [ ! -x "${CAST_BIN}" ]; then
  {
    echo "$(_ts) [ERROR] cast binary not found or not executable: ${CAST_BIN}"
    echo "$(_ts) [ERROR] Skipping integrity check — install CAST and ensure ${HOME}/.local/bin/cast exists"
  } >> "${LOG_FILE}"
  exit 0
fi

# ── Run `cast integrity` ──────────────────────────────────────────────────────
INTEGRITY_OUTPUT="$("${CAST_BIN}" integrity 2>&1 || true)"

# Strip ANSI colour codes so the log is readable and grep is reliable.
CLEAN_OUTPUT="$(printf '%s' "${INTEGRITY_OUTPUT}" | sed 's/\x1b\[[0-9;]*[mKJH]//g')"

# ── Append timestamped block to audit log ────────────────────────────────────
{
  echo "=== $(_ts) ==="
  printf '%s\n' "${CLEAN_OUTPUT}"
  echo "=== end ==="
  echo ""
} >> "${LOG_FILE}"

# ── Parse warn count from summary line ───────────────────────────────────────
# Expected format: "integrity: N ok, M warn, K info"
WARN_COUNT="$(printf '%s' "${CLEAN_OUTPUT}" \
  | grep -Eo 'integrity: [0-9]+ ok, [0-9]+ warn' \
  | grep -Eo '[0-9]+ warn' \
  | grep -Eo '[0-9]+' \
  || echo "")"

if [ -z "${WARN_COUNT}" ]; then
  echo "$(_ts) [WARN] Could not parse warn count from integrity output — skipping baseline check" >> "${LOG_FILE}"
  exit 0
fi

# ── Baseline-delta check ──────────────────────────────────────────────────────
if [ ! -f "${BASELINE_FILE}" ]; then
  # First-ever run: establish the baseline silently (no notification).
  echo "${WARN_COUNT}" > "${BASELINE_FILE}"
  echo "$(_ts) [INFO] Baseline established: warn_count=${WARN_COUNT}" >> "${LOG_FILE}"
  exit 0
fi

PREV_COUNT="$(cat "${BASELINE_FILE}" 2>/dev/null || echo "0")"

if [ "${WARN_COUNT}" -gt "${PREV_COUNT}" ]; then
  # Regression: warn count rose above baseline → notify.
  MSG="CAST integrity regressed: ${PREV_COUNT} → ${WARN_COUNT} warnings — run: cast integrity"
  echo "$(_ts) [REGRESSION] ${MSG}" >> "${LOG_FILE}"

  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${MSG}\" with title \"CAST Integrity\"" || true
  fi
fi

# Always update the baseline (captures both increases and decreases).
echo "${WARN_COUNT}" > "${BASELINE_FILE}"
echo "$(_ts) [INFO] Baseline updated: prev=${PREV_COUNT} current=${WARN_COUNT}" >> "${LOG_FILE}"

exit 0
