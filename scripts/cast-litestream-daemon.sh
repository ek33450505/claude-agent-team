#!/usr/bin/env bash
# cast-litestream-daemon.sh — Wrapper executed by the com.cast.litestream LaunchAgent.
#
# Resolves the litestream binary (Homebrew-aware PATH), then execs
# `litestream replicate -config <config>`.
#
# Missing binary or config → log one line to stderr + exit 1.
# launchd KeepAlive handles back-off / retry.
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
  echo "ERROR [cast-litestream-daemon]: litestream binary not found in PATH. Install via Homebrew." >&2
  exit 1
fi

# ---- Verify config exists -------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR [cast-litestream-daemon]: config not found at ${CONFIG_FILE}. Run cast-litestream-setup.sh first." >&2
  exit 1
fi

# ---- Exec (replace this shell with litestream) ----------------------------
exec "${LITESTREAM_BIN}" replicate -config "${CONFIG_FILE}"
