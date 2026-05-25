#!/usr/bin/env bash
# sync-ecosystem-readme.sh — atomically sync the ECOSYSTEM block from docs/ecosystem.md
# into a target README between <!-- ECOSYSTEM_START --> and <!-- ECOSYSTEM_END --> markers.
#
# Usage:
#   sync-ecosystem-readme.sh [--repo <path>] [--target-readme <relative-path>]
#
# Defaults:
#   --repo           current directory (must be the claude-agent-team root)
#   --target-readme  README.md (relative to --repo)
#
# Exit codes:
#   0  success — block replaced (or already identical, idempotent)
#   1  markers missing in source or target; no change made

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR sync-ecosystem-readme: $1" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

# ── Defaults ────────────────────────────────────────────────────────────────
REPO_PATH="$(pwd)"
TARGET_README="README.md"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_PATH="${2:?--repo requires a path argument}"
      shift 2
      ;;
    --target-readme)
      TARGET_README="${2:?--target-readme requires a path argument}"
      shift 2
      ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--repo <path>] [--target-readme <relative-path>]" >&2
      exit 1
      ;;
  esac
done

# ── Resolve paths ────────────────────────────────────────────────────────────
SOURCE_ECOSYSTEM="${REPO_PATH}/docs/ecosystem.md"
TARGET_FILE="${REPO_PATH}/${TARGET_README}"

if [[ ! -f "${SOURCE_ECOSYSTEM}" ]]; then
  echo "ERROR: source ecosystem doc not found: ${SOURCE_ECOSYSTEM}" >&2
  _log_error "source not found: ${SOURCE_ECOSYSTEM}"
  exit 1
fi

if [[ ! -f "${TARGET_FILE}" ]]; then
  echo "ERROR: target README not found: ${TARGET_FILE}" >&2
  _log_error "target not found: ${TARGET_FILE}"
  exit 1
fi

# ── Extract block from source ─────────────────────────────────────────────────
START_MARKER="<!-- ECOSYSTEM_START -->"
END_MARKER="<!-- ECOSYSTEM_END -->"

if ! grep -qF "${START_MARKER}" "${SOURCE_ECOSYSTEM}"; then
  echo "ERROR: ${START_MARKER} not found in ${SOURCE_ECOSYSTEM}" >&2
  _log_error "ECOSYSTEM_START marker missing from source: ${SOURCE_ECOSYSTEM}"
  exit 1
fi

if ! grep -qF "${END_MARKER}" "${SOURCE_ECOSYSTEM}"; then
  echo "ERROR: ${END_MARKER} not found in ${SOURCE_ECOSYSTEM}" >&2
  _log_error "ECOSYSTEM_END marker missing from source: ${SOURCE_ECOSYSTEM}"
  exit 1
fi

# Extract lines strictly between the markers (markers themselves not included in body,
# but we keep them in the replacement so the target stays valid for future runs).
SOURCE_BLOCK="$(awk \
  "/$(printf '%s' "${START_MARKER}" | sed 's/[\/&]/\\&/g')/{found=1; print; next} \
   /$(printf '%s' "${END_MARKER}" | sed 's/[\/&]/\\&/g')/{print; found=0; next} \
   found{print}" \
  "${SOURCE_ECOSYSTEM}")"

# Build the full replacement block (markers + inner content)
REPLACEMENT="${START_MARKER}
${SOURCE_BLOCK}
${END_MARKER}"

# ── Verify target has both markers ───────────────────────────────────────────
if ! grep -qF "${START_MARKER}" "${TARGET_FILE}"; then
  echo "ERROR: ${START_MARKER} not found in ${TARGET_FILE}" >&2
  _log_error "ECOSYSTEM_START marker missing from target: ${TARGET_FILE}"
  exit 1
fi

if ! grep -qF "${END_MARKER}" "${TARGET_FILE}"; then
  echo "ERROR: ${END_MARKER} not found in ${TARGET_FILE}" >&2
  _log_error "ECOSYSTEM_END marker missing from target: ${TARGET_FILE}"
  exit 1
fi

# ── Atomic replacement ────────────────────────────────────────────────────────
TMPFILE="$(mktemp)"

# Use awk to replace the block between markers in the target file
awk \
  -v start="${START_MARKER}" \
  -v end="${END_MARKER}" \
  -v replacement="${REPLACEMENT}" \
  'BEGIN { inside=0; printed=0 }
   $0 == start {
     if (!printed) { print replacement; printed=1 }
     inside=1
     next
   }
   $0 == end {
     inside=0
     next
   }
   !inside { print }
  ' \
  "${TARGET_FILE}" > "${TMPFILE}"

# Count changed lines for the report
BEFORE_LINES="$(grep -c '' "${TARGET_FILE}" 2>/dev/null || echo 0)"
AFTER_LINES="$(grep -c '' "${TMPFILE}" 2>/dev/null || echo 0)"
DELTA=$(( AFTER_LINES - BEFORE_LINES ))

mv "${TMPFILE}" "${TARGET_FILE}"

echo "Updated ecosystem block in ${TARGET_FILE} (${DELTA:+$DELTA lines changed}${DELTA:-0 lines changed — already up to date})"
