#!/usr/bin/env bash
# cast-litestream-verify.sh — Prove the Litestream replica is restorable.
#
# Steps:
#   1. Locate config (CAST_LITESTREAM_ROOT override, default ~/Library/Application Support/cast)
#   2. Verify litestream binary, config, and non-empty replica directory exist
#   3. litestream restore -config <yml> -o <tmpdir>/restored.db <db-path>
#   4. sqlite3 restored.db "PRAGMA integrity_check;" must return "ok"
#   5. Freshness: newest replica file mtime vs live cast.db mtime
#      (STALE if db is >1h newer; python3 for mtime math — no BSD stat -f / date -v)
#   6. Print PASS/FAIL summary; exit 0 only when all checks pass.
#
# Environment overrides (primarily for testing):
#   CAST_DB_PATH          — path to cast.db (default: ~/.claude/cast.db)
#   CAST_LITESTREAM_ROOT  — base for config/replica (default: ~/Library/Application Support/cast)
#
# Exit codes:
#   0 — PASS (restore + integrity + freshness all passed)
#   1 — FAIL (one or more checks failed; message indicates which step)
#
# Cleanup: the restored temp DB is deleted via cast-guard-lib.sh (cast_safe_rm).
# No bare rm -rf is used — blast-radius lint enforces this.

# Subprocess guard (CAST convention — must precede set -euo pipefail)
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# ---- Source blast-radius guard lib ------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cast-guard-lib.sh
source "${SCRIPT_DIR}/cast-guard-lib.sh" || {
  echo "FAIL [cast-litestream-verify]: could not source cast-guard-lib.sh" >&2
  exit 1
}

# Declare blast radius for the mktemp restore directory.
# Prefixes canonicalize at registration: /tmp → /private/tmp on macOS.
_VERIFY_TMP_PREFIX="cast-ls-verify-"
cast_declare_blast_radius \
  "/tmp/${_VERIFY_TMP_PREFIX}" \
  "/private/tmp/${_VERIFY_TMP_PREFIX}"

# ---- Resolve paths ----------------------------------------------------------

CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
CAST_LITESTREAM_ROOT="${CAST_LITESTREAM_ROOT:-${HOME}/Library/Application Support/cast}"
CONFIG_FILE="${CAST_LITESTREAM_ROOT}/litestream.yml"
REPLICA_DIR="${CAST_LITESTREAM_ROOT}/litestream/cast-db"

# ---- Cleanup trap -----------------------------------------------------------

RESTORE_TMP=""
_verify_cleanup() {
  if [[ -n "${RESTORE_TMP}" ]]; then
    cast_safe_rm "${RESTORE_TMP}" 2>/dev/null || true
  fi
}
trap _verify_cleanup EXIT

# ---- Failure tracking -------------------------------------------------------

_PASS=1
_FAIL_REASONS=()

_fail() {
  _PASS=0
  _FAIL_REASONS+=("$1")
  echo "FAIL: $1" >&2
}

# ---- Step 1: litestream binary ----------------------------------------------

if ! command -v litestream > /dev/null 2>&1; then
  echo "FAIL [cast-litestream-verify]: litestream binary not found in PATH." >&2
  echo "  Install: brew install litestream" >&2
  echo "  (or: brew tap benbjohnson/litestream && brew install litestream)" >&2
  echo "  Replica cannot be verified without the litestream binary." >&2
  exit 1
fi

# ---- Step 2: config present -------------------------------------------------

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "FAIL [cast-litestream-verify]: config not found: ${CONFIG_FILE}" >&2
  echo "  Run cast-litestream-setup.sh to create the config." >&2
  exit 1
fi

# ---- Step 3: replica directory non-empty ------------------------------------

if [[ ! -d "${REPLICA_DIR}" ]]; then
  echo "FAIL [cast-litestream-verify]: replica directory not found: ${REPLICA_DIR}" >&2
  echo "  The litestream daemon has not yet created a replica. Start it and wait." >&2
  exit 1
fi

_REPLICA_FILE_COUNT="$(find "${REPLICA_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${_REPLICA_FILE_COUNT}" -eq 0 ]]; then
  echo "FAIL [cast-litestream-verify]: replica directory is empty: ${REPLICA_DIR}" >&2
  echo "  No replica data found. Start the litestream daemon and wait for initial snapshot." >&2
  exit 1
fi

# ---- Step 4: restore --------------------------------------------------------

RESTORE_TMP="$(mktemp -d "/tmp/${_VERIFY_TMP_PREFIX}XXXXXX")"
RESTORED_DB="${RESTORE_TMP}/restored.db"

echo "[cast-litestream-verify] Restoring replica → ${RESTORED_DB} ..."
if ! litestream restore -config "${CONFIG_FILE}" -o "${RESTORED_DB}" "${CAST_DB_PATH}"; then
  _fail "litestream restore command failed"
fi

# ---- Step 5: integrity check ------------------------------------------------

if [[ "${_PASS}" -eq 1 ]]; then
  echo "[cast-litestream-verify] Running PRAGMA integrity_check ..."
  _INTEGRITY="$(sqlite3 "${RESTORED_DB}" "PRAGMA integrity_check;" 2>&1)" \
    || _INTEGRITY="ERROR"
  if [[ "${_INTEGRITY}" != "ok" ]]; then
    _fail "PRAGMA integrity_check: ${_INTEGRITY}"
  else
    echo "[cast-litestream-verify] Integrity: ok"
  fi
fi

# ---- Step 6: freshness check (python3 — cross-platform mtime math) ----------

echo "[cast-litestream-verify] Checking freshness ..."
_FRESHNESS="$(python3 - "${CAST_DB_PATH}" "${REPLICA_DIR}" <<'PYEOF'
import sys
import os

db_path = sys.argv[1]
replica_dir = sys.argv[2]

# Get live DB mtime
try:
    db_mtime = os.path.getmtime(db_path)
except OSError as e:
    print("WARN: cannot stat live DB: {}".format(e))
    sys.exit(0)

# Find the newest file mtime under the replica directory
newest = 0.0
for root, dirs, files in os.walk(replica_dir):
    for fname in files:
        try:
            m = os.path.getmtime(os.path.join(root, fname))
            if m > newest:
                newest = m
        except OSError:
            pass

if newest == 0.0:
    print("STALE: no files found under replica directory")
    sys.exit(0)

diff = db_mtime - newest
if diff > 3600:
    print("STALE: live DB is {}s newer than newest replica file (threshold: 3600s)".format(int(diff)))
elif diff >= 0:
    print("FRESH: replica is {}s behind live DB (within 1h threshold)".format(int(diff)))
else:
    print("FRESH: replica mtime leads live DB by {}s".format(int(-diff)))

sys.exit(0)
PYEOF
)" || _FRESHNESS="PYERROR: python3 invocation failed"

if [[ "${_FRESHNESS}" == STALE* ]]; then
  _fail "freshness: ${_FRESHNESS}"
elif [[ "${_FRESHNESS}" == PYERROR* ]]; then
  _fail "${_FRESHNESS}"
else
  echo "[cast-litestream-verify] Freshness: ${_FRESHNESS}"
fi

# ---- Summary ----------------------------------------------------------------

echo ""
if [[ "${_PASS}" -eq 1 ]]; then
  echo "PASS [cast-litestream-verify]: restore + integrity + freshness all passed."
  exit 0
else
  echo "FAIL [cast-litestream-verify]: the following checks failed:"
  for _reason in "${_FAIL_REASONS[@]}"; do
    echo "  - ${_reason}"
  done
  exit 1
fi
