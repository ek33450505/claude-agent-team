#!/usr/bin/env bash
# cast-hook-lib.sh — Shared boilerplate for CAST hook scripts
#
# Provides two small functions extracted from the ~19-24 hook scripts that
# duplicate the same two lines verbatim:
#   cast_hook_read_stdin() — sets INPUT from stdin (never fails on empty/closed stdin)
#   cast_hook_db_path()    — sets DB_PATH from CAST_DB_PATH, falling back to ~/.claude/cast.db
#
# Usage:
#   source "$(dirname "$0")/cast-hook-lib.sh"   # or full path
#   cast_hook_read_stdin   # sets $INPUT
#   cast_hook_db_path      # sets $DB_PATH
#
# Both functions assign into the caller's shell (no subshell escape) since
# this file is sourced, not executed — matching the inlined pattern exactly.

# Guard: source-safe, no side effects on re-source.
if [[ -n "${_CAST_HOOK_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_CAST_HOOK_LIB_LOADED=1

cast_hook_read_stdin() {
  INPUT="$(cat 2>/dev/null || true)"
}

cast_hook_db_path() {
  DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
}
