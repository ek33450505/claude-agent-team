#!/bin/bash
# cast-plugin-install.sh — CAST plugin post-install script.
# Runs after scripts/ are copied to ~/.claude/scripts/ by the plugin installer.
#
# Actions:
#   1. Create required CAST runtime directories
#   2. Initialize/migrate cast.db
#   3. Validate required dependencies (python3, jq, sqlite3)
#   4. chmod +x all scripts in ~/.claude/scripts/
#   5. Print success message with version
#
# Usage:
#   bash scripts/cast-plugin-install.sh
#
# Environment:
#   CAST_SCRIPTS_DIR   Override scripts install path (default: ~/.claude/scripts)
#   CAST_DB_PATH       Override cast.db path (default: ~/.claude/cast.db)

set -euo pipefail

CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"
CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
CLAUDE_DIR="${HOME}/.claude"

# Resolve version from repo root VERSION file, then installed cast-version, then fallback
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAST_VERSION="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null \
  || cat "${CLAUDE_DIR}/cast-version" 2>/dev/null \
  || echo "unknown")"

# --- Color helpers ---
_green()  { printf '\033[0;32m%s\033[0m\n' "$1"; }
_yellow() { printf '\033[0;33m%s\033[0m\n' "$1"; }
_red()    { printf '\033[0;31m%s\033[0m\n' "$1"; }
_cyan()   { printf '\033[0;36m%s\033[0m\n' "$1"; }

printf '\nCAST plugin post-install (v%s)\n' "$CAST_VERSION"

# --- Step 1: Create required directories ---
_cyan "Creating runtime directories..."
for dir in \
  "${CLAUDE_DIR}/agent-memory-local" \
  "${CLAUDE_DIR}/cast/events" \
  "${CLAUDE_DIR}/agent-status" \
  "${CLAUDE_DIR}/logs" \
  "${CLAUDE_DIR}/plans" \
  "${CLAUDE_DIR}/briefings" \
  "${CLAUDE_DIR}/reports" \
  "${CLAUDE_DIR}/cast/state" \
  "${CLAUDE_DIR}/cast/offline-queue" \
  "${CLAUDE_DIR}/cast/reviews" \
  "${CLAUDE_DIR}/cast/artifacts" \
  "${CLAUDE_DIR}/config"
do
  mkdir -p "$dir"
done
_green "  Directories ready"

# --- Step 2: Initialize/migrate cast.db ---
_cyan "Initializing cast.db..."
DB_INIT="${CAST_SCRIPTS_DIR}/cast-db-init.sh"
if [ -f "$DB_INIT" ]; then
  if CAST_DB_PATH="$CAST_DB_PATH" bash "$DB_INIT" 2>/dev/null; then
    _green "  cast.db initialized"
  else
    _yellow "  Warning: cast-db-init.sh failed — run it manually to initialize cast.db"
  fi
else
  _yellow "  Warning: cast-db-init.sh not found at ${DB_INIT}"
  _yellow "  copy scripts/ to ${CAST_SCRIPTS_DIR} before running this script"
fi

# --- Step 3: Validate dependencies ---
_cyan "Checking dependencies..."
MISSING=0

check_dep() {
  local cmd="$1"
  local min_ver="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    _green "  $cmd: found ($(command -v "$cmd"))"
  else
    _red "  $cmd: NOT FOUND (required: ${min_ver})"
    MISSING=$((MISSING + 1))
  fi
}

check_dep python3 ">=3.9"
check_dep jq     ">=1.6"
check_dep sqlite3 "any"

if [ "$MISSING" -gt 0 ]; then
  _red "  $MISSING required dependency/dependencies missing — install them before using CAST"
fi

# --- Step 4: chmod +x all scripts ---
_cyan "Setting script permissions..."
if [ -d "$CAST_SCRIPTS_DIR" ]; then
  find "$CAST_SCRIPTS_DIR" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) \
    -exec chmod +x {} \;
  _green "  Permissions set on scripts in ${CAST_SCRIPTS_DIR}"
else
  _yellow "  Scripts directory not found: ${CAST_SCRIPTS_DIR}"
fi

# --- Step 5: Print success ---
printf '\n'
if [ "$MISSING" -eq 0 ]; then
  _green "CAST v${CAST_VERSION} installed successfully."
else
  _yellow "CAST v${CAST_VERSION} installed with warnings — fix missing dependencies above."
fi
printf '\nNext steps:\n'
printf '  cast status    — verify health\n'
printf '  cast doctor    — detailed health check\n'
printf '  cast agents    — list installed agents\n\n'
