#!/usr/bin/env bash
# gen-stats.sh — CAST README dynamic stats updater
# Counts actual agents/commands/skills/tests/routes and updates sentinel tokens in README.md
# Usage: bash scripts/gen-stats.sh [path/to/README.md]
#
# Sentinel format in README:  <!-- CAST_AGENT_COUNT -->29<!-- /CAST_AGENT_COUNT -->

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
README="${1:-$REPO_DIR/README.md}"

# --- Counts ---
# After restructure, bash-specialist moved to core/ — all agents live in subdirs
AGENT_COUNT=$(find "$REPO_DIR/agents" -mindepth 2 -name "*.md" | wc -l | tr -d ' ')
CMD_COUNT=$(find "$REPO_DIR/commands" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
# Skills: count unique skill dirs (exclude linux variant dirs that are install-time substitutes)
SKILL_COUNT=$(find "$REPO_DIR/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
# Tests: top-level *.bats only (excludes embedded bats framework test files)
TEST_COUNT=$(grep -h "^@test" "$REPO_DIR/tests"/*.bats 2>/dev/null | wc -l | tr -d ' ')
ROUTE_COUNT=$(python3 -c "
import json, sys
try:
    data = json.load(open('$REPO_DIR/config/routing-table.json'))
    print(len(data.get('routes', data) if isinstance(data, dict) else data))
except Exception:
    print(21)
" 2>/dev/null || echo 21)

# --- Update sentinel tokens in README ---
update_token() {
  local token="$1" value="$2" file="$3"
  # Matches: <!-- TOKEN -->anything<!-- /TOKEN -->
  sed -i.bak "s|<!-- ${token} -->[^<]*<!-- /${token} -->|<!-- ${token} -->${value}<!-- /${token} -->|g" "$file"
}

if [ ! -f "$README" ]; then
  echo "README not found: $README" >&2
  exit 1
fi

update_token "CAST_AGENT_COUNT"   "$AGENT_COUNT"   "$README"
update_token "CAST_COMMAND_COUNT" "$CMD_COUNT"     "$README"
update_token "CAST_SKILL_COUNT"   "$SKILL_COUNT"   "$README"
update_token "CAST_TEST_COUNT"    "$TEST_COUNT"    "$README"
update_token "CAST_ROUTE_COUNT"   "$ROUTE_COUNT"   "$README"

# --- Update shields.io badge URLs ---
sed -i.bak "s|/badge/agents-[0-9]*-green|/badge/agents-${AGENT_COUNT}-green|g" "$README"
sed -i.bak "s|/badge/tests-[0-9]*%20passing|/badge/tests-${TEST_COUNT}%20passing|g" "$README"
sed -i.bak "s|/badge/routes-[0-9]*-|/badge/routes-${ROUTE_COUNT}-|g" "$README"

rm -f "${README}.bak"

echo "CAST stats updated:"
echo "  Agents:   $AGENT_COUNT"
echo "  Commands: $CMD_COUNT"
echo "  Skills:   $SKILL_COUNT"
echo "  Tests:    $TEST_COUNT"
echo "  Routes:   $ROUTE_COUNT"
