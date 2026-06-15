#!/usr/bin/env bash
# cast-plugin-bootstrap.sh — CAST plugin SessionStart bootstrap.
# Runs as a hook command from inside the plugin (${CLAUDE_PLUGIN_ROOT} is set).
# Must be idempotent and fast (~15s hook budget).
#
# Actions:
#   1. Resolve PLUGIN_ROOT from ${CLAUDE_PLUGIN_ROOT} or script location
#   2. Create required CAST runtime dirs under ~/.claude
#   3. Symlink plugin scripts into ~/.claude/scripts/ (idempotent)
#   4. Init cast.db if missing or stale (guarded — never fails the hook)
#
# IMPORTANT: Never exit non-zero — a SessionStart hook must not break the session.

set -euo pipefail

# --- Resolve plugin root ---
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CLAUDE_DIR="${HOME}/.claude"
CAST_SCRIPTS_DIR="${CLAUDE_DIR}/scripts"
CAST_DB_PATH="${CAST_DB_PATH:-${CLAUDE_DIR}/cast.db}"

# Wrap all work in a subshell so we can trap errors and exit 0
_bootstrap_main() {
  # --- Step 1: Create runtime dirs ---
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
    "${CLAUDE_DIR}/config" \
    "${CLAUDE_DIR}/backups" \
    "${CAST_SCRIPTS_DIR}"
  do
    mkdir -p "$dir"
  done

  # --- Step 2: Symlink plugin scripts into ~/.claude/scripts/ ---
  # For each file in ${PLUGIN_ROOT}/scripts/, create a symlink in ~/.claude/scripts/
  # if one doesn't already exist or is stale (ln -sf is idempotent).
  local plugin_scripts="${PLUGIN_ROOT}/scripts"
  if [[ -d "$plugin_scripts" ]]; then
    while IFS= read -r -d '' src; do
      local fname
      fname="$(basename "$src")"
      local dst="${CAST_SCRIPTS_DIR}/${fname}"
      # Only create/update the symlink — never overwrite a non-symlink file
      if [[ -L "$dst" ]] || [[ ! -e "$dst" ]]; then
        ln -sf "$src" "$dst"
      fi
    done < <(find "$plugin_scripts" -maxdepth 1 -type f -print0)
  fi

  # --- Step 3: Init cast.db (guarded — only when missing or schema is stale) ---
  local db_init="${CAST_SCRIPTS_DIR}/cast-db-init.sh"
  if [[ ! -f "${CAST_DB_PATH}" ]]; then
    # DB is missing — run init
    if [[ -f "$db_init" ]]; then
      CAST_DB_PATH="$CAST_DB_PATH" bash "$db_init" 2>/dev/null \
        || printf '[CAST bootstrap] Warning: cast-db-init.sh failed — cast.db may be uninitialized\n' >&2
    else
      printf '[CAST bootstrap] Warning: cast-db-init.sh not found at %s\n' "$db_init" >&2
    fi
  else
    # DB exists — probe PRAGMA user_version (set by cast-db-init.sh); run init only if 0
    local schema_ver
    schema_ver="$(sqlite3 "${CAST_DB_PATH}" "PRAGMA user_version;" 2>/dev/null || echo "0")"
    if [[ -z "$schema_ver" || "$schema_ver" == "0" ]]; then
      if [[ -f "$db_init" ]]; then
        CAST_DB_PATH="$CAST_DB_PATH" bash "$db_init" 2>/dev/null \
          || printf '[CAST bootstrap] Warning: cast-db-init.sh failed during schema update\n' >&2
      fi
    fi
    # Warm path: user_version > 0 → skip (near-no-op)
  fi
}

# Run with error trap — never let a failure propagate out of the hook
if ! _bootstrap_main 2>/dev/null; then
  printf '[CAST bootstrap] Warning: bootstrap encountered an error — session continues normally\n' >&2
fi

exit 0
