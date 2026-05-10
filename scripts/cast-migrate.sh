#!/bin/bash
# Migration runner for cast.db schema evolution
# Usage: scripts/cast-migrate.sh [--db PATH]
# Idempotent: reads schema_migrations table, applies any migrations not yet recorded

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# Resolve DB path
DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"
if [[ $# -gt 0 ]] && [[ "$1" == "--db" ]]; then
  DB_PATH="$2"
fi

# Resolve migrations directory relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MIGRATIONS_DIR="$REPO_ROOT/migrations"

# Ensure migrations directory exists
if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  mkdir -p "$MIGRATIONS_DIR"
fi

# Initialize schema_migrations table if it doesn't exist
sqlite3 -cmd ".timeout 5000" "$DB_PATH" "
CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT (datetime('now')),
  checksum TEXT
);
"

# Find all migration files in lexicographic order
# Use nullglob to handle empty directory gracefully on macOS
shopt -s nullglob
migration_files=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob

# Track applied count
applied_count=0

# Process each migration file
for migration_file in "${migration_files[@]}"; do
  version=$(basename "$migration_file" .sql)

  # Check if this migration has already been applied
  exists=$(sqlite3 -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT COUNT(*) FROM schema_migrations WHERE version = '$version';" 2>/dev/null || echo "0")

  if [[ "$exists" -gt 0 ]]; then
    continue
  fi

  # Special handling for baseline marker: record as applied without executing
  if [[ "$version" == *"-baseline" ]]; then
    sqlite3 -cmd ".timeout 5000" "$DB_PATH" \
      "INSERT INTO schema_migrations (version, applied_at, checksum) VALUES ('$version', datetime('now'), 'baseline-marker');"
    echo "[migrate] applied $version"
    applied_count=$((applied_count + 1))
  else
    # Read and execute the migration file
    migration_content=$(<"$migration_file")

    # Compute checksum
    checksum=$(echo -n "$migration_content" | shasum -a 256 | awk '{print $1}')

    # Validate checksum format: 64 lowercase hex chars. Defense-in-depth before SQL interpolation.
    if [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
      echo "[migrate] ERROR: invalid checksum for $version" >&2
      exit 1
    fi

    # Execute migration
    if sqlite3 -cmd ".timeout 5000" "$DB_PATH" <<EOF
$migration_content
EOF
    then
      # Record as applied on success
      sqlite3 -cmd ".timeout 5000" "$DB_PATH" \
        "INSERT INTO schema_migrations (version, applied_at, checksum) VALUES ('$version', datetime('now'), '$checksum');"
      echo "[migrate] applied $version"
      applied_count=$((applied_count + 1))
    else
      # Migration failed: exit 1 to stop the world
      echo "[migrate] ERROR: migration $version failed" >&2
      exit 1
    fi
  fi
done

# Report result
if [[ $applied_count -eq 0 ]]; then
  echo "[migrate] (none)"
fi

exit 0
