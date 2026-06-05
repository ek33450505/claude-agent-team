#!/usr/bin/env bash
# cast-stats-lib.sh — Sourceable library of CAST stat derivation functions.
# NOT executable standalone. Source this file, then call the functions.
#
# Each function cd's to repo root internally and echoes a single value.
# Callers own set -euo pipefail — this file does NOT set it at the top level
# (sourcing with set -e active in the caller would kill the caller on any
# subcommand failure inside a function; functions use local error handling).
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/cast-stats-lib.sh"
#   AGENT_COUNT=$(cast_stat_agents)

# Resolve repo root once, relative to THIS file (BASH_SOURCE, never $0).
CAST_STATS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# cast_stat_version — echoes version string from VERSION file (whitespace stripped)
cast_stat_version() {
  tr -d '[:space:]' < "${CAST_STATS_REPO_ROOT}/VERSION"
}

# cast_stat_agents — count tracked agent definition files under agents/core/
cast_stat_agents() {
  (
    cd "${CAST_STATS_REPO_ROOT}"
    git ls-files 'agents/core/*.md' | grep -cE '^agents/core/[^/]+\.md$' | tr -d ' '
  )
}

# cast_stat_commands — count tracked command files under commands/
cast_stat_commands() {
  (
    cd "${CAST_STATS_REPO_ROOT}"
    git ls-files 'commands/*.md' | wc -l | tr -d ' '
  )
}

# cast_stat_skills — count unique skill dirs (any tracked file under skills/<dir>/)
cast_stat_skills() {
  (
    cd "${CAST_STATS_REPO_ROOT}"
    git ls-files 'skills/*' | grep -oE '^skills/[^/]+' | sort -u | wc -l | tr -d ' '
  )
}

# cast_stat_tests — count @test functions across all tracked .bats files
cast_stat_tests() {
  (
    cd "${CAST_STATS_REPO_ROOT}"
    TEST_FILES=$(git ls-files 'tests/*.bats' 'tests/*/*.bats')
    if [[ -n "$TEST_FILES" ]]; then
      echo "$TEST_FILES" | xargs grep -h "^@test" 2>/dev/null | wc -l | tr -d ' '
    else
      echo 0
    fi
  )
}

# cast_stat_tables — count DISTINCT table names across canonical schema sources.
# Covers cast-db-init.sh + scripts/migrations/*.sql + migrations/*.sql.
# Must yield 38.
cast_stat_tables() {
  (
    cd "${CAST_STATS_REPO_ROOT}"
    COUNT=$(
      grep -rhoE 'CREATE TABLE IF NOT EXISTS[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(' \
        scripts/cast-db-init.sh scripts/migrations/*.sql migrations/*.sql 2>/dev/null | \
        sed -E 's/.*EXISTS[[:space:]]+//;s/[[:space:]]*\(//' | \
        sort -u | wc -l
    ) || COUNT=0
    echo "$COUNT" | tr -d ' '
  )
}

# cast_stat_packages — count of CAST Homebrew taps (not derivable from this repo's filesystem).
# Taps: homebrew-cast, homebrew-cast-dash, homebrew-cast-hooks, homebrew-cast-agents,
#       homebrew-cast-desktop, homebrew-cast-doctor, homebrew-cast-memory,
#       homebrew-cast-observe, homebrew-cast-parallel, homebrew-cast-routines,
#       homebrew-cast-security, homebrew-cast-time, homebrew-claudes-journal = 13.
# Update CAST_PACKAGES_COUNT when the tap set changes.
cast_stat_packages() {
  echo "${CAST_PACKAGES_COUNT:-13}"
}
