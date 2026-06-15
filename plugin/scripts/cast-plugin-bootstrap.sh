#!/usr/bin/env bash
# cast-plugin-bootstrap.sh — CAST plugin SessionStart bootstrap.
# Runs as a hook command from inside the plugin (${CLAUDE_PLUGIN_ROOT} is set).
# Must be idempotent and fast (~15s hook budget).
#
# Actions:
#   1. Resolve PLUGIN_ROOT from ${CLAUDE_PLUGIN_ROOT} or script location
#   2. Create required CAST runtime dirs under ~/.claude
#   3. Prune broken plugin-managed symlinks in ~/.claude/scripts/ (Fix #7/#40)
#   4. Symlink plugin scripts into ~/.claude/scripts/ (idempotent, never-clobber)
#   5. Init cast.db if missing or stale (guarded — never fails the hook)
#
# IMPORTANT: Never exit non-zero — a SessionStart hook must not break the session.
# IMPORTANT: set -e is intentionally NOT relied upon for resilience inside
#   _bootstrap_main — every critical step is checked explicitly with a warning
#   on failure (Fix #8).  set -euo pipefail governs the outer script only so
#   variable typos / unbound vars are still caught at parse-time, but the
#   function itself runs in best-effort mode with per-step checks.

set -euo pipefail

# --- Resolve plugin root ---
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CLAUDE_DIR="${HOME}/.claude"
CAST_SCRIPTS_DIR="${CLAUDE_DIR}/scripts"
CAST_DB_PATH="${CAST_DB_PATH:-${CLAUDE_DIR}/cast.db}"

# _warn — write a visible warning to stderr (not swallowed).
_warn() { printf '[CAST bootstrap] WARNING: %s\n' "$*" >&2; }

# Wrap all work in a function; called in best-effort mode (see bottom).
# set -e is DISABLED inside this function when called via "{ _bootstrap_main; } || true"
# — that is intentional.  Each step that can fail is checked explicitly.
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
    mkdir -p "$dir" || _warn "mkdir failed for $dir"
  done

  local plugin_scripts="${PLUGIN_ROOT}/scripts"

  # --- Step 2: Prune broken plugin-managed symlinks (Fix #7/#40) ---
  # When a plugin update removes or renames a script, the old symlink in
  # ~/.claude/scripts/ becomes dangling.  Remove ONLY symlinks that are:
  #   (a) broken  ([[ -L f && ! -e f ]])
  #   (b) pointing into THIS plugin's scripts dir (not another plugin/install)
  # Never touch real files or valid symlinks or links pointing elsewhere.
  if [[ -d "${CAST_SCRIPTS_DIR}" ]]; then
    local f link_target
    for f in "${CAST_SCRIPTS_DIR}/"*; do
      # Must be a symlink AND broken (target does not exist)
      [[ -L "$f" && ! -e "$f" ]] || continue
      link_target="$(readlink "$f" 2>/dev/null || true)"
      # Only remove if the broken link's target was inside our plugin scripts dir
      if [[ -n "$link_target" && "$link_target" == "${plugin_scripts}/"* ]]; then
        # Prefer cast_safe_rm if available; fall back to a guarded rm
        if command -v cast_safe_rm >/dev/null 2>&1; then
          cast_safe_rm "$f" || _warn "cast_safe_rm failed for broken symlink $f"
        else
          rm -- "$f" || _warn "rm failed for broken symlink $f"
        fi
      fi
    done
  fi

  # --- Step 3: Symlink plugin scripts into ~/.claude/scripts/ ---
  # For each file in ${PLUGIN_ROOT}/scripts/, create a symlink in ~/.claude/scripts/
  # if one doesn't already exist or the slot is already a symlink (idempotent update).
  # Never overwrite a non-symlink (real) file.
  if [[ -d "$plugin_scripts" ]]; then
    local src fname dst
    while IFS= read -r -d '' src; do
      fname="$(basename "$src")"
      dst="${CAST_SCRIPTS_DIR}/${fname}"
      # Only create/update the symlink — never overwrite a non-symlink file
      if [[ -L "$dst" ]] || [[ ! -e "$dst" ]]; then
        ln -sf "$src" "$dst" || _warn "ln -sf failed for $fname"
      fi
    done < <(find "$plugin_scripts" -maxdepth 1 -type f -print0)
  else
    _warn "plugin scripts dir not found: $plugin_scripts — skipping symlink step"
  fi

  # --- Step 4: Init cast.db (guarded — only when missing or schema is stale) ---
  local db_init="${CAST_SCRIPTS_DIR}/cast-db-init.sh"
  if [[ ! -f "${CAST_DB_PATH}" ]]; then
    # DB is missing — run init
    if [[ -f "$db_init" ]]; then
      CAST_DB_PATH="$CAST_DB_PATH" bash "$db_init" 2>/dev/null \
        || _warn "cast-db-init.sh failed — cast.db may be uninitialized"
    else
      _warn "cast-db-init.sh not found at $db_init — cast.db not created"
    fi
  else
    # DB exists — probe PRAGMA user_version (set by cast-db-init.sh); run init only if 0
    local schema_ver
    schema_ver="$(sqlite3 "${CAST_DB_PATH}" "PRAGMA user_version;" 2>/dev/null || echo "0")"
    if [[ -z "$schema_ver" || "$schema_ver" == "0" ]]; then
      if [[ -f "$db_init" ]]; then
        CAST_DB_PATH="$CAST_DB_PATH" bash "$db_init" 2>/dev/null \
          || _warn "cast-db-init.sh failed during schema update"
      fi
    fi
    # Warm path: user_version > 0 → skip (near-no-op)
  fi
}

# Run in best-effort mode: errors inside _bootstrap_main produce visible warnings
# to stderr but never propagate — the session always continues.
# NOTE: "|| true" (not "2>/dev/null") so that the _warn calls inside the function
# reach stderr and are visible.  The outer "set -e" is neutralised for this call
# by the "|| true" idiom, which is the honest, intentional design.
{ _bootstrap_main; } || true

exit 0
