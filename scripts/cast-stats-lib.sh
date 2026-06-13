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
# Covers cast-db-init.sh + scripts/migrations/*.sql.
# Must yield 36 (35 + eval_runs added in v8-A3).
cast_stat_tables() {
  (
    cd "${CAST_STATS_REPO_ROOT}"
    COUNT=$(
      grep -rhoE 'CREATE TABLE IF NOT EXISTS[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(' \
        scripts/cast-db-init.sh scripts/migrations/*.sql 2>/dev/null | \
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

# cast_stats_assert_floors — plausibility guard against silent stat breakage.
# Args: AGENTS TESTS TABLES COMMANDS SKILLS PACKAGES VERSION
# Prints one "[cast-stats] FLOOR VIOLATION: ..." line per failure to stderr.
# Returns 0 if every stat meets its floor, 1 otherwise. Never exits (sourcing-safe).
cast_stats_assert_floors() {
  local agents="${1:-}" tests="${2:-}" tables="${3:-}" commands="${4:-}" \
        skills="${5:-}" packages="${6:-}" version="${7:-}"
  local violations=0
  _cast_stats_floor() { # name value min
    local name="$1" value="$2" min="$3"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ]; then
      printf '[cast-stats] FLOOR VIOLATION: %s=%s below minimum %s\n' "$name" "$value" "$min" >&2
      violations=$((violations + 1))
    fi
  }
  _cast_stats_floor agents   "$agents"   20
  _cast_stats_floor tests    "$tests"    1000
  _cast_stats_floor tables   "$tables"   30
  _cast_stats_floor commands "$commands" 10
  _cast_stats_floor skills   "$skills"   5
  _cast_stats_floor packages "$packages" 10
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '[cast-stats] FLOOR VIOLATION: version=%s is not a valid semver\n' "$version" >&2
    violations=$((violations + 1))
  fi
  [ "$violations" -eq 0 ]
}
