#!/usr/bin/env bash
# cast-sqlite-lib.sh — Shared sqlite3 wrapper for CAST shell scripts
#
# Provides cast_sqlite(): a drop-in sqlite3 wrapper that prepends
# PRAGMA busy_timeout=5000 so every invocation waits up to 5 s for
# a WAL write-lock instead of failing immediately with SQLITE_BUSY.
#
# Usage:
#   source "$(dirname "$0")/cast-sqlite-lib.sh"   # or full path
#   cast_sqlite "$DB_PATH" "SELECT 1;"
#   cast_sqlite "$DB_PATH" << 'EOF'
#     INSERT INTO ...;
#   EOF
#
# The wrapper is a thin shim — it does NOT re-open the connection between
# statements, so multi-statement heredocs still run in a single sqlite3
# session (one lock acquisition).

# Guard: source-safe, no side effects on re-source.
if [[ -n "${_CAST_SQLITE_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_CAST_SQLITE_LIB_LOADED=1

cast_sqlite() {
  # Usage: cast_sqlite <db_path> [sql_string]
  # With no sql_string, reads SQL from stdin (heredoc-friendly).
  local db_path="${1:?cast_sqlite: db_path required}"
  shift

  if [[ $# -gt 0 ]]; then
    # Inline SQL mode: prepend busy_timeout pragma and pass remaining args.
    sqlite3 "$db_path" "PRAGMA busy_timeout=5000;" "$@"
  else
    # Stdin / heredoc mode: prepend pragma via process substitution so the
    # caller's heredoc is not consumed twice.
    { printf 'PRAGMA busy_timeout=5000;\n'; cat; } | sqlite3 "$db_path"
  fi
}
