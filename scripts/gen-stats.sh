#!/usr/bin/env bash
# gen-stats.sh — CAST README dynamic stats updater
# Counts actual agents/commands/skills/tests/routes and updates sentinel tokens in README.md
# Usage: bash scripts/gen-stats.sh [path/to/README.md]
#
# Sentinel format in README:  <!-- CAST_AGENT_COUNT -->29<!-- /CAST_AGENT_COUNT -->

set -euo pipefail

# BATS guard — refuse to mutate README.md when called during BATS test execution.
# BATS sets these env vars in every test run; their presence means we're inside
# a test gate and any side-effect on the real README is a leak.
if [[ -n "${BATS_TEST_NAME:-}" || -n "${BATS_TEST_FILENAME:-}" || -n "${BATS_TMPDIR:-}" ]]; then
  echo "[gen-stats] BATS context detected — skipping README mutation" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
README="${1:-$REPO_DIR/README.md}"

# --- Counts (sourced from shared lib — single source of truth) ---
# Use `git ls-files` to count only TRACKED files. Counting untracked or in-flight
# files (find/ls) causes pre-commit-vs-CI divergence — the pre-commit auto-staged
# stats reflect untracked-but-on-disk files that CI can't see, so readme-in-sync
# fails. Tracked-only is the only deterministic, CI-stable count.
# shellcheck source=scripts/cast-stats-lib.sh
source "${SCRIPT_DIR}/cast-stats-lib.sh"
cd "$REPO_DIR"
AGENT_COUNT=$(cast_stat_agents)
CMD_COUNT=$(cast_stat_commands)
SKILL_COUNT=$(cast_stat_skills)
TEST_COUNT=$(cast_stat_tests)
# Routes removed in CAST v3 — model-driven dispatch via CLAUDE.md
ROUTE_COUNT=0
DB_TABLE_COUNT=$(cast_stat_tables)

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

update_all_tokens() {
  local file="$1"
  update_token "CAST_AGENT_COUNT"    "$AGENT_COUNT"    "$file"
  update_token "CAST_COMMAND_COUNT"  "$CMD_COUNT"      "$file"
  update_token "CAST_SKILL_COUNT"    "$SKILL_COUNT"    "$file"
  update_token "CAST_TEST_COUNT"     "$TEST_COUNT"     "$file"
  update_token "CAST_ROUTE_COUNT"    "$ROUTE_COUNT"    "$file"
  update_token "CAST_DB_TABLE_COUNT" "$DB_TABLE_COUNT" "$file"
}

update_all_tokens "$README"

# Also walk docs/ for any other files that carry sentinel tokens. Files without
# sentinels are untouched (sed is a no-op on them). Files with sentinels stay
# fresh on every gen-stats run, just like README.md.
if [ -d "$REPO_DIR/docs" ]; then
  while IFS= read -r doc; do
    [ -f "$doc" ] || continue
    if grep -q "<!-- CAST_" "$doc" 2>/dev/null; then
      update_all_tokens "$doc"
      rm -f "${doc}.bak"
      echo "  refreshed: $doc"
    fi
  done < <(find "$REPO_DIR/docs" -name '*.md' -type f 2>/dev/null)
fi

# --- Update version badge sentinel ---
VERSION_FILE="$REPO_DIR/VERSION"
CAST_VERSION="$(cast_stat_version)"
if [ -f "$VERSION_FILE" ]; then
  NEW_BADGE="![Version](https://img.shields.io/badge/version-${CAST_VERSION}-blue)"
  sed -i.bak "s|<!-- CAST_VERSION_BADGE -->.*<!-- /CAST_VERSION_BADGE -->|<!-- CAST_VERSION_BADGE -->${NEW_BADGE}<!-- /CAST_VERSION_BADGE -->|g" "$README"
fi

# --- Update shields.io badge URLs ---
# Agents: matches /badge/agents-<N>-<color>
sed -i.bak -E "s|/badge/agents-[0-9]+-[a-z]+|/badge/agents-${AGENT_COUNT}-green|g" "$README"
# Tests: matches both /badge/tests-<N>-<color> (plain) and /badge/tests-<N>%20<word> (legacy "total" form)
sed -i.bak -E "s|/badge/tests-[0-9]+-[a-z]+|/badge/tests-${TEST_COUNT}-brightgreen|g" "$README"
sed -i.bak -E "s|/badge/tests-[0-9]+%20[a-z]+|/badge/tests-${TEST_COUNT}-brightgreen|g" "$README"
# Version: matches /badge/version-<X.Y[.Z]>-<color>
if [ -f "$VERSION_FILE" ]; then
  sed -i.bak -E "s|/badge/version-[0-9]+(\.[0-9]+){0,2}-[a-z]+|/badge/version-${CAST_VERSION}-blue|g" "$README"
fi
rm -f "${README}.bak"

echo "CAST stats updated:"
echo "  Agents:    $AGENT_COUNT"
echo "  Commands:  $CMD_COUNT"
echo "  Skills:    $SKILL_COUNT"
echo "  Tests:     $TEST_COUNT"
echo "  DB tables: $DB_TABLE_COUNT"
[ -f "$VERSION_FILE" ] && echo "  Version:   $CAST_VERSION"
