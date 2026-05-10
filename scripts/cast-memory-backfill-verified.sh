#!/bin/bash
# cast-memory-backfill-verified.sh — backfill verified_at in auto-memory frontmatter
# Phase 4.8.3: add verified_at timestamp to memories that don't have one.
# Idempotent: safe to rerun.
# Usage: cast-memory-backfill-verified.sh [--dry-run] [--target-date YYYY-MM-DD]

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# Parse arguments
DRY_RUN=0
TARGET_DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --target-date)
      TARGET_DATE="$2"
      shift 2
      ;;
    *)
      printf "Unknown option: %s\n" "$1" >&2
      exit 1
      ;;
  esac
done

# Default target date to today UTC
if [ -z "$TARGET_DATE" ]; then
  TARGET_DATE=$(date -u +%Y-%m-%d)
fi

# Validate date format
if ! [[ "$TARGET_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  printf "Invalid date format: %s (expected YYYY-MM-DD)\n" "$TARGET_DATE" >&2
  exit 1
fi

STAMPED=0
SKIPPED=0

# Walk all memory files
while IFS= read -r memory_file; do
  # Skip MEMORY.md index files
  if [[ "$memory_file" == *"/MEMORY.md" ]]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Check if file has a frontmatter block
  if ! grep -q "^---$" "$memory_file"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Check if verified_at already exists
  if grep -q "^verified_at:" "$memory_file"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Use Python to insert verified_at before closing ---
  if [ "$DRY_RUN" = 1 ]; then
    STAMPED=$((STAMPED + 1))
    continue
  fi

  # In-place insert via Python
  export FILE_PATH="$memory_file"
  export TARGET_DATE
  python3 << 'PYEOF'
import os

file_path = os.environ.get('FILE_PATH', '')
if not file_path:
  exit(1)

with open(file_path, 'r') as f:
  lines = f.readlines()

# Find first and second ---
first_dash = -1
second_dash = -1
for i, line in enumerate(lines):
  if line.strip() == '---':
    if first_dash == -1:
      first_dash = i
    elif second_dash == -1:
      second_dash = i
      break

if first_dash == -1 or second_dash == -1:
  exit(1)

# Check if verified_at exists between first and second ---
has_verified_at = False
for i in range(first_dash + 1, second_dash):
  if lines[i].startswith('verified_at:'):
    has_verified_at = True
    break

if has_verified_at:
  exit(0)

# Insert before second ---
target_date = os.environ.get('TARGET_DATE', '')
new_line = f'verified_at: {target_date}\n'
lines.insert(second_dash, new_line)

with open(file_path, 'w') as f:
  f.writelines(lines)
PYEOF

  STAMPED=$((STAMPED + 1))
done < <(find ~/.claude/projects -name "*.md" -type f 2>/dev/null | grep -v MEMORY.md)

printf "[backfill] stamped %d files, skipped %d (already had verified_at or invalid)\n" "$STAMPED" "$SKIPPED"
