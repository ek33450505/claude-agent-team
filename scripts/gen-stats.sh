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

# --- Counts ---
# Use `git ls-files` to count only TRACKED files. Counting untracked or in-flight
# files (find/ls) causes pre-commit-vs-CI divergence — the pre-commit auto-staged
# stats reflect untracked-but-on-disk files that CI can't see, so readme-in-sync
# fails. Tracked-only is the only deterministic, CI-stable count.
cd "$REPO_DIR"
AGENT_COUNT=$(git ls-files 'agents/core/*.md' | grep -cE '^agents/core/[^/]+\.md$' | tr -d ' ')
CMD_COUNT=$(git ls-files 'commands/*.md' | wc -l | tr -d ' ')
# Skills: count unique skill dirs (any tracked file under skills/<dir>/)
SKILL_COUNT=$(git ls-files 'skills/*' | grep -oE '^skills/[^/]+' | sort -u | wc -l | tr -d ' ')
# Tests: count individual @test functions across all tracked .bats files
TEST_FILES=$(git ls-files 'tests/*.bats' 'tests/*/*.bats')
if [ -n "$TEST_FILES" ]; then
  TEST_COUNT=$(echo "$TEST_FILES" | xargs grep -h "^@test" 2>/dev/null | wc -l | tr -d ' ')
else
  TEST_COUNT=0
fi
# Routes removed in CAST v3 — model-driven dispatch via CLAUDE.md
ROUTE_COUNT=0

# DB tables: count CREATE TABLE IF NOT EXISTS across canonical schema sources
# (init script + both migration directories). This counts the tables the framework
# ships with, not a particular user's live cast.db (which may have FTS sidecars
# or accumulated state from past versions).
DB_TABLE_COUNT=0
for f in scripts/cast-db-init.sh scripts/migrations/*.sql migrations/*.sql; do
  if [ -f "$f" ]; then
    # grep -c emits a count on stdout AND exits 1 when count is 0;
    # the `|| echo 0` shim re-prints "0", producing a multi-line value
    # that breaks $(()). Suppress stderr, redirect to /dev/null on miss.
    n=$(grep -cE "CREATE TABLE IF NOT EXISTS" "$f" 2>/dev/null) || n=0
    DB_TABLE_COUNT=$((DB_TABLE_COUNT + n))
  fi
done

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

update_token "CAST_AGENT_COUNT"    "$AGENT_COUNT"    "$README"
update_token "CAST_COMMAND_COUNT"  "$CMD_COUNT"      "$README"
update_token "CAST_SKILL_COUNT"    "$SKILL_COUNT"    "$README"
update_token "CAST_TEST_COUNT"     "$TEST_COUNT"     "$README"
update_token "CAST_ROUTE_COUNT"    "$ROUTE_COUNT"    "$README"
update_token "CAST_DB_TABLE_COUNT" "$DB_TABLE_COUNT" "$README"

# --- Update version badge sentinel ---
VERSION_FILE="$REPO_DIR/VERSION"
if [ -f "$VERSION_FILE" ]; then
  CAST_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
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
