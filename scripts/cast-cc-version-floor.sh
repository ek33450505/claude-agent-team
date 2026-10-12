#!/usr/bin/env bash
# cast-cc-version-floor.sh — WARN when Claude Code predates hook onFailure support.
#
# Hook field "onFailure": "block" needs Claude Code >= 2.1.295. On older
# versions the field is inert and CAST guards fail OPEN on timeout/crash.
# Prints ONE warning line to stdout when below the floor (or when the version
# cannot be determined); prints nothing otherwise. ALWAYS exits 0 — this is a
# WARN and must never abort install. bash 3.2 compatible.

# Subprocess guard
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

FLOOR_MAJOR=2
FLOOR_MINOR=1
FLOOR_PATCH=295
FLOOR_STR="${FLOOR_MAJOR}.${FLOOR_MINOR}.${FLOOR_PATCH}"

_could_not_determine() {
    echo "WARNING: could not determine Claude Code version — hook onFailure:\"block\" needs >= ${FLOOR_STR}; if older, CAST guards fail OPEN on timeout/crash. Upgrade Claude Code."
    exit 0
}

if ! command -v claude >/dev/null 2>&1; then
    _could_not_determine
fi

RAW="$(claude --version 2>/dev/null || true)"
VER="${RAW%%[[:space:]]*}"

if ! [[ "$VER" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    _could_not_determine
fi

# 10# forces base-10 so a leading zero is never read as octal.
MAJOR=$((10#${BASH_REMATCH[1]}))
MINOR=$((10#${BASH_REMATCH[2]}))
PATCH=$((10#${BASH_REMATCH[3]}))

LOW=0
if [ "$MAJOR" -lt "$FLOOR_MAJOR" ]; then
    LOW=1
elif [ "$MAJOR" -eq "$FLOOR_MAJOR" ]; then
    if [ "$MINOR" -lt "$FLOOR_MINOR" ]; then
        LOW=1
    elif [ "$MINOR" -eq "$FLOOR_MINOR" ] && [ "$PATCH" -lt "$FLOOR_PATCH" ]; then
        LOW=1
    fi
fi

if [ "$LOW" -eq 1 ]; then
    echo "WARNING: Claude Code ${VER} < ${FLOOR_STR} — hook onFailure:\"block\" is inert; CAST guards fail OPEN on timeout/crash. Upgrade Claude Code."
fi
exit 0
