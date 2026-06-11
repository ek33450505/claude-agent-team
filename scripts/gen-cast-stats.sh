#!/usr/bin/env bash
# gen-cast-stats.sh — Generate cast-stats.json at repo root.
#
# Usage:
#   bash scripts/gen-cast-stats.sh           # write cast-stats.json
#   bash scripts/gen-cast-stats.sh --check   # compare in-memory vs committed file, exit 1 if stale
#
# Environment overrides:
#   CAST_STATS_DATE   override the 'updated' field (useful in tests to pin date)

set -euo pipefail

# BATS guard — when called inside a BATS test run, skip stat derivation and exit 0.
# BATS's own @test blocks (including tests/cast-stats.bats) add to the @test count,
# which would make --check always fail from within BATS context. The committed
# cast-stats.json reflects counts at commit time, not inside a test run.
if [[ -n "${BATS_TEST_NAME:-}" || -n "${BATS_TEST_FILENAME:-}" || -n "${BATS_TMPDIR:-}" ]]; then
  # Only skip if --check is requested (the flag that would produce false positives).
  # Bare invocation (write mode) is also suppressed since writing during BATS would
  # overwrite the committed file with inflated counts.
  echo "[gen-cast-stats] BATS context detected — skipping" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/cast-stats-lib.sh
source "${SCRIPT_DIR}/cast-stats-lib.sh"

CHECK_MODE=0
for arg in "$@"; do
  if [[ "$arg" == "--check" ]]; then
    CHECK_MODE=1
  fi
done

# Gather stats
VER="$(cast_stat_version)"
AGENTS="$(cast_stat_agents)"
TESTS="$(cast_stat_tests)"
TABLES="$(cast_stat_tables)"
COMMANDS="$(cast_stat_commands)"
SKILLS="$(cast_stat_skills)"
PACKAGES="$(cast_stat_packages)"
UPDATED="${CAST_STATS_DATE:-$(date +%F)}"

# Plausibility floor — abort if any derived stat is implausibly low. Runs in BOTH
# write and --check mode so a silent-0 can never pass (breaks the green-while-broken
# tautology where --check re-derives the same broken value and compares it to itself).
if ! cast_stats_assert_floors "$AGENTS" "$TESTS" "$TABLES" "$COMMANDS" "$SKILLS" "$PACKAGES" "$VER"; then
  echo "[gen-cast-stats] ABORT: derived stats failed plausibility floor (see above)." >&2
  echo "  A stat derivation likely broke silently. Fix the derivation — do NOT lower the floor." >&2
  exit 1
fi

# Build JSON (all numeric fields as JSON numbers, not strings)
JSON="$(jq -n \
  --arg version "$VER" \
  --arg versionTag "v${VER}" \
  --argjson agents "$AGENTS" \
  --argjson tests "$TESTS" \
  --argjson tables "$TABLES" \
  --argjson commands "$COMMANDS" \
  --argjson skills "$SKILLS" \
  --argjson packages "$PACKAGES" \
  --arg updated "$UPDATED" \
  --arg source "https://raw.githubusercontent.com/ek33450505/claude-agent-team/main/cast-stats.json" \
  --arg generator "scripts/gen-cast-stats.sh" \
  '{
    version: $version,
    versionTag: $versionTag,
    agents: $agents,
    tests: $tests,
    tables: $tables,
    commands: $commands,
    skills: $skills,
    packages: $packages,
    updated: $updated,
    "_source": $source,
    "_generator": $generator
  }')"

STATS_FILE="${REPO_ROOT}/cast-stats.json"

if [[ "$CHECK_MODE" -eq 1 ]]; then
  # Compare in-memory JSON vs committed file, ignoring 'updated' field
  if [[ ! -f "$STATS_FILE" ]]; then
    echo "[gen-cast-stats] ERROR: cast-stats.json not found at ${STATS_FILE}" >&2
    echo "Run: bash scripts/gen-cast-stats.sh  to generate it." >&2
    exit 1
  fi
  CANONICAL=$(echo "$JSON" | jq -S 'del(.updated)')
  COMMITTED=$(jq -S 'del(.updated)' < "$STATS_FILE")
  if diff_output=$(diff <(echo "$COMMITTED") <(echo "$CANONICAL")); then
    echo "[gen-cast-stats] cast-stats.json is in sync." >&2
    exit 0
  else
    echo "[gen-cast-stats] DRIFT DETECTED — cast-stats.json is stale:" >&2
    echo "$diff_output" >&2
    echo "" >&2
    echo "Run: bash scripts/gen-cast-stats.sh  to regenerate." >&2
    exit 1
  fi
fi

# Default: write the file
echo "$JSON" > "$STATS_FILE"
echo "[gen-cast-stats] wrote ${STATS_FILE}" >&2
echo "  version:  $VER" >&2
echo "  agents:   $AGENTS" >&2
echo "  tests:    $TESTS" >&2
echo "  tables:   $TABLES" >&2
echo "  commands: $COMMANDS" >&2
echo "  skills:   $SKILLS" >&2
echo "  packages: $PACKAGES" >&2
echo "  updated:  $UPDATED" >&2
