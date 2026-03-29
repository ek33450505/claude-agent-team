#!/bin/bash
# cast-archive.sh — CAST auto-archive hook
# Hook event: Stop
# Usage: cast-archive.sh [--dry-run] [--verbose]
#
# Purpose:
#   On session end, move stale files from ~/.claude/ to ~/Archive/claude-archive-auto/
#   and prune old rows from cast.db. Runs fast (< 2s), silent unless archiving occurs.
#
# Exit codes:
#   0 — always (hook must not block session close)

set +e

# --- Subprocess guard — do not run inside CAST subagents ---
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

# --- TTL config (days) ---
TTL_PLANS=14
TTL_DEBUG=7
TTL_SHELL_SNAPSHOTS=14
TTL_PASTE_CACHE=7
TTL_REPORTS=30
TTL_DB_ROWS=90

# --- Argument parsing ---
DRY_RUN=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
  esac
done

CLAUDE_DIR="${HOME}/.claude"
ARCHIVE_BASE="${HOME}/Archive/claude-archive-auto"

# --- archive_category <src_dir> <name_pat_or_empty> <type_f_flag> <dest_subdir> <ttl_days> <label> ---
# name_pat_or_empty: glob pattern for -name, e.g. "*.txt" or "[0-9]*-*.md" — pass "" to skip -name filter
# type_f_flag: "1" to add -type f to the find command, "0" to omit (used when name_pat already implies files)
archive_category() {
  local src="$1"
  local name_pat="$2"
  local type_f="$3"
  local dest_sub="$4"
  local ttl="$5"
  local label="$6"

  # Skip if source directory does not exist
  [ -d "$src" ] || return 0

  local dest="${ARCHIVE_BASE}/${dest_sub}"
  local count=0
  local dest_created=0

  # Build find command as an array — safe quoting, no glob expansion of name_pat
  local find_cmd=( find "$src" -maxdepth 1 )
  [ -n "$name_pat" ] && find_cmd+=( -name "$name_pat" )
  [ "$type_f" = "1" ] && find_cmd+=( -type f )
  find_cmd+=( -mtime +"$ttl" -print0 )

  while IFS= read -r -d '' f; do
    # Skip symlinks (catches debug/latest and any other symlinks)
    [ -L "$f" ] && continue
    # Skip directories
    [ -f "$f" ] || continue

    if [ "$DRY_RUN" -eq 1 ]; then
      [ "$VERBOSE" -eq 1 ] && echo "[cast-archive] dry-run: would archive ${f}" >&2
      count=$((count + 1))
    else
      # Create dest dir on first file (lazy — only when there's something to archive)
      if [ "$dest_created" -eq 0 ]; then
        mkdir -p "$dest" 2>/dev/null || {
          echo "[cast-archive] WARN: cannot create ${dest}" >&2
          return 0
        }
        dest_created=1
      fi
      if ! mv "$f" "$dest/" 2>/dev/null; then
        echo "[cast-archive] WARN: failed to archive ${f}" >&2
        continue
      fi
      count=$((count + 1))
    fi
  done < <( "${find_cmd[@]}" 2>/dev/null )

  if [ "$count" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[cast-archive] dry-run: ${label}: ${count} would be archived → ~/Archive/claude-archive-auto/${dest_sub}" >&2
    else
      echo "[cast-archive] ${label}: ${count} archived → ~/Archive/claude-archive-auto/${dest_sub}" >&2
    fi
  fi
}

# --- File archiving ---

# Plans: only YYYY-MM-DD-*.md (date-prefixed completed plans); name_pat implies files, skip -type f
archive_category \
  "${CLAUDE_DIR}/plans" \
  "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md" \
  "0" \
  "plans" \
  "$TTL_PLANS" \
  "plans"

# Debug logs: *.txt files only (the 'latest' symlink is skipped by symlink guard)
archive_category \
  "${CLAUDE_DIR}/debug" \
  "*.txt" \
  "0" \
  "debug" \
  "$TTL_DEBUG" \
  "debug"

# Shell snapshots: all regular files (no name filter)
archive_category \
  "${CLAUDE_DIR}/shell-snapshots" \
  "" \
  "1" \
  "shell-snapshots" \
  "$TTL_SHELL_SNAPSHOTS" \
  "shell-snapshots"

# Paste cache: all regular files (no name filter)
archive_category \
  "${CLAUDE_DIR}/paste-cache" \
  "" \
  "1" \
  "paste-cache" \
  "$TTL_PASTE_CACHE" \
  "paste-cache"

# Reports: all regular files (no name filter)
archive_category \
  "${CLAUDE_DIR}/reports" \
  "" \
  "1" \
  "reports" \
  "$TTL_REPORTS" \
  "reports"

# --- DB pruning ---
DB="${CLAUDE_DIR}/cast.db"
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    AR_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM agent_runs WHERE started_at < datetime('now', '-${TTL_DB_ROWS} days');" 2>/dev/null || echo 0)
    S_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE started_at < datetime('now', '-${TTL_DB_ROWS} days');" 2>/dev/null || echo 0)
    [ "$AR_COUNT" -gt 0 ] 2>/dev/null && echo "[cast-archive] dry-run: would delete ${AR_COUNT} agent_runs rows older than ${TTL_DB_ROWS} days" >&2 || true
    [ "$S_COUNT" -gt 0 ] 2>/dev/null && echo "[cast-archive] dry-run: would delete ${S_COUNT} sessions rows older than ${TTL_DB_ROWS} days" >&2 || true
  else
    sqlite3 "$DB" "DELETE FROM agent_runs WHERE started_at < datetime('now', '-${TTL_DB_ROWS} days');" 2>/dev/null || true
    sqlite3 "$DB" "DELETE FROM sessions WHERE started_at < datetime('now', '-${TTL_DB_ROWS} days');" 2>/dev/null || true
  fi
fi

exit 0
