#!/usr/bin/env bash
# Count planned @test entries across given .bats files.
# Usage: cast-count-planned-tests.sh [file1.bats file2.bats ...]
# Output: integer count on stdout (always exits 0 — graceful degradation)
#
# Counts only lines that start with exactly "@test" (no indentation, no "#").
# Unreadable or missing files are silently skipped (counted as 0).
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo 0
  exit 0
fi

count=0
for f in "$@"; do
  if [[ -r "$f" ]]; then
    c=$(grep -c "^@test" "$f" 2>/dev/null) || c=0
    count=$(( count + c ))
  fi
done
echo "$count"
