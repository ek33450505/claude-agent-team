#!/usr/bin/env bash
# cast-litestream-daemon.sh — Wrapper executed by the com.cast.litestream LaunchAgent.
#
# Resolves the litestream binary (Homebrew-aware PATH), then execs
# `litestream replicate -config <config>`.
#
# Preflight failures (missing binary or missing config) → log one advisory line
# and exit 0 (clean exit = launchd stops retrying since KeepAlive is dict form
# with SuccessfulExit=false). Real litestream crashes still exit non-zero and
# will trigger a restart.
#
# Environment:
#   CAST_LITESTREAM_ROOT  — root for AppSupport layout (default: ~/Library/Application Support/cast)

# Subprocess guard (CAST convention)
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# Prepend Homebrew paths so `command -v` finds litestream regardless of whether
# launchd inherited a full user PATH.
# CAST_LITESTREAM_PATH_PREFIX can be overridden in tests to a directory without litestream.
_path_prefix="${CAST_LITESTREAM_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin}"
export PATH="${_path_prefix}:${PATH}"

CAST_LITESTREAM_ROOT="${CAST_LITESTREAM_ROOT:-${HOME}/Library/Application Support/cast}"
CONFIG_FILE="${CAST_LITESTREAM_ROOT}/litestream.yml"

# ---- Resolve litestream binary -------------------------------------------
LITESTREAM_BIN="$(command -v litestream 2>/dev/null || true)"
if [[ -z "${LITESTREAM_BIN}" ]]; then
  echo "ADVISORY [cast-litestream-daemon]: litestream binary not found in PATH — install via: brew install benbjohnson/litestream/litestream" >&2
  exit 0
fi

# ---- Verify config exists -------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ADVISORY [cast-litestream-daemon]: config not found at ${CONFIG_FILE} — run: bash scripts/cast-litestream-setup.sh" >&2
  exit 0
fi

# ---- Exec (replace this shell with litestream) ----------------------------
exec "${LITESTREAM_BIN}" replicate -config "${CONFIG_FILE}"
