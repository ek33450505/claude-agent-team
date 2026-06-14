#!/bin/bash
# cast-seed-user-profile.sh — One-time seeder for initial user_profile facts about Ed
#
# Idempotent: uses INSERT OR IGNORE to skip entries that already exist.
# Run once on fresh install; safe to run multiple times (no duplicates).
#
# Usage:
#   bash scripts/cast-seed-user-profile.sh
#
# Output: prints count of inserted facts and any errors to stderr

set -euo pipefail

# shellcheck source=cast-sqlite-lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cast-sqlite-lib.sh" 2>/dev/null || true

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# Ensure DB exists
if [ ! -f "$DB_PATH" ]; then
  echo "Warning: cast.db not found at $DB_PATH; cannot seed user_profile facts" >&2
  exit 0
fi

# Seed facts as (type, name, agent, project, content, confidence)
# These are person-specific facts that follow Ed across all projects
FACTS=(
  "user_profile|work_hours|global||8am-4pm M-F (META Solutions), evenings+weekends (personal projects)|0.9"
  "user_profile|communication_style|global||Direct, terse responses. No trailing summaries of what was just done. No emojis.|1.0"
  "user_profile|goal|global||Targeting an Anthropic role; CAST + dashboard + Homebrew tap are the portfolio pieces|0.9"
  "user_profile|working_style|global||Builds in long sessions, manages context deliberately, uses compact/resume workflow, compacts at ~60%|0.8"
  "user_profile|domain_primary|global||Software engineering, ed-tech (Ohio school districts), META Solutions full-stack|0.9"
  "user_profile|stack_preference|global||Shell (bash) + Python for CAST/hooks; React+Vite+Express for dashboards|0.8"
)

INSERTED=0
SKIPPED=0

for fact in "${FACTS[@]}"; do
  IFS='|' read -r mem_type name agent project content confidence <<< "$fact"

  # Validate confidence is strictly numeric before use in SQL (guards against
  # accidental non-numeric values from the FACTS array — safe even though the
  # array is hardcoded, because the lint and good hygiene both require it).
  if [[ ! "$confidence" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Warning: skipping fact '$name' — confidence '$confidence' is not numeric" >&2
    continue
  fi

  # Read probe — intentionally raw sqlite3 (fail-fast read; no write lock needed)
  EXISTING=$(sqlite3 "$DB_PATH" \
    "SELECT id FROM agent_memories WHERE type='$mem_type' AND name='$name' AND agent='$agent' LIMIT 1;" 2>/dev/null || echo "")

  if [ -z "$EXISTING" ]; then
    # Insert new fact
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cast_sqlite "$DB_PATH" <<EOF
INSERT INTO agent_memories (type, name, agent, project, content, confidence, created_at, updated_at)
VALUES ('$mem_type', '$name', '$agent', NULL, '$content', '$confidence', '$NOW', '$NOW');
EOF
    ((INSERTED++)) || true
  else
    ((SKIPPED++)) || true
  fi
done

echo "User profile seeding complete: $INSERTED inserted, $SKIPPED already existing" >&2
exit 0
