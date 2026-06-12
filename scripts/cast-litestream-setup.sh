#!/usr/bin/env bash
# cast-litestream-setup.sh — Idempotent setup for Litestream continuous DB replication.
#
# Creates the required directory layout and writes litestream.yml.
# If litestream is not installed, prints an advisory and exits 0 (opt-in tool).
#
# Environment overrides (primarily for testing):
#   CAST_DB_PATH          — path to cast.db (default: ~/.claude/cast.db)
#   CAST_LITESTREAM_ROOT  — base for config/replica/logs (default: ~/Library/Application Support/cast)
#
# Exit codes:
#   0 — success or litestream not installed (advisory only)
#   1 — unexpected error

# Subprocess guard (CAST convention)
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# ---- Resolve paths -------------------------------------------------------

CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
CAST_LITESTREAM_ROOT="${CAST_LITESTREAM_ROOT:-${HOME}/Library/Application Support/cast}"

CONFIG_DIR="${CAST_LITESTREAM_ROOT}"
REPLICA_DIR="${CAST_LITESTREAM_ROOT}/litestream/cast-db"
LOGS_DIR="${CAST_LITESTREAM_ROOT}/logs"
CONFIG_FILE="${CONFIG_DIR}/litestream.yml"

# ---- Check litestream binary ----------------------------------------------

if ! command -v litestream > /dev/null 2>&1; then
  echo "ADVISORY [cast-litestream-setup]: litestream not installed." >&2
  echo "  Install via: brew install litestream  (or: brew tap benbjohnson/litestream && brew install litestream)" >&2
  echo "  Continuous DB replication is opt-in — skipping setup." >&2
  exit 0
fi

# ---- Create directory layout ----------------------------------------------

mkdir -p "${REPLICA_DIR}"
mkdir -p "${LOGS_DIR}"

# ---- Write litestream.yml (idempotent) ------------------------------------
# Use a temp file + atomic move so partial writes never leave a broken config.

TMP_CONFIG="$(mktemp "${CONFIG_DIR}/.litestream-tmp-XXXXXX")"
trap 'rm -f "${TMP_CONFIG}"' EXIT

cat > "${TMP_CONFIG}" <<YAML
dbs:
  - path: ${CAST_DB_PATH}
    replicas:
      - type: file
        path: ${REPLICA_DIR}
YAML

# Only replace the config if the content has changed (idempotency).
if [[ -f "${CONFIG_FILE}" ]] && cmp -s "${TMP_CONFIG}" "${CONFIG_FILE}"; then
  rm -f "${TMP_CONFIG}"
  echo "cast-litestream-setup: config already up to date at ${CONFIG_FILE}"
else
  mv "${TMP_CONFIG}" "${CONFIG_FILE}"
  echo "cast-litestream-setup: wrote config to ${CONFIG_FILE}"
fi

echo "cast-litestream-setup: directories ready"
echo "  config : ${CONFIG_FILE}"
echo "  replica: ${REPLICA_DIR}"
echo "  logs   : ${LOGS_DIR}"
