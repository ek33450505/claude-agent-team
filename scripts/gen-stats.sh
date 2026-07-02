#!/usr/bin/env bash
# gen-stats.sh — CAST README dynamic stats updater
# Counts actual agents/commands/skills/tests/routes and updates sentinel tokens in README.md
# Usage: bash scripts/gen-stats.sh [path/to/README.md] [--check]
#
# Sentinel format in README:  <!-- CAST_AGENT_COUNT -->29<!-- /CAST_AGENT_COUNT -->
# --check: compare computed stats vs README sentinels and badge URLs (read-only).
#          Exits 0 if in sync, 1 if drift detected. Writes nothing.

set -euo pipefail

# --- Argument parsing (must happen before BATS guard so --check can bypass it) ---
CHECK_MODE=0
README_ARG=""
for arg in "$@"; do
  if [[ "$arg" == "--check" ]]; then
    CHECK_MODE=1
  elif [[ "$arg" == "--"* ]]; then
    echo "Usage: gen-stats.sh [path/to/README.md] [--check]" >&2
    exit 2
  else
    if [[ -n "$README_ARG" ]]; then
      echo "Usage: gen-stats.sh [path/to/README.md] [--check]" >&2
      exit 2
    fi
    README_ARG="$arg"
  fi
done

# BATS guard — refuse to mutate README.md when called during BATS test execution.
# BATS sets these env vars in every test run; their presence means we're inside
# a test gate and any side-effect on the real README is a leak.
# --check is read-only so it runs normally under BATS; mutation mode keeps the guard.
if [[ "$CHECK_MODE" -eq 0 ]]; then
  if [[ -n "${BATS_TEST_NAME:-}" || -n "${BATS_TEST_FILENAME:-}" || -n "${BATS_TMPDIR:-}" ]]; then
    echo "[gen-stats] BATS context detected — skipping README mutation" >&2
    exit 0
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
README="${README_ARG:-$REPO_DIR/README.md}"

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
TEST_FILE_COUNT=$(cast_stat_test_files)
# Routes removed in CAST v3 — model-driven dispatch via CLAUDE.md
ROUTE_COUNT=0
DB_TABLE_COUNT=$(cast_stat_tables)
VERSION_FILE="$REPO_DIR/VERSION"
CAST_VERSION="$(cast_stat_version)"

# Plausibility floor (same guard as gen-cast-stats.sh) — fail loudly on silent-0.
if ! cast_stats_assert_floors "$AGENT_COUNT" "$TEST_COUNT" "$DB_TABLE_COUNT" "$CMD_COUNT" "$SKILL_COUNT" "$(cast_stat_packages)" "$CAST_VERSION"; then
  echo "[gen-stats] ABORT: derived stats failed plausibility floor (see above)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# CHECK MODE — read-only comparison; no writes, no .bak files
# ---------------------------------------------------------------------------
if [[ "$CHECK_MODE" -eq 1 ]]; then
  if [ ! -f "$README" ]; then
    echo "[gen-stats] --check: README not found: $README" >&2
    exit 1
  fi

  DRIFT=0

  # read_token TOKEN FILE — extracts the value between <!-- TOKEN --> and <!-- /TOKEN -->
  # Returns empty string if the sentinel is absent.
  read_token() {
    local token="$1" file="$2"
    sed -n "s|.*<!-- ${token} -->\([^<]*\)<!-- /${token} -->.*|\1|p" "$file" | head -1
  }

  # check_token TOKEN EXPECTED FILE — skips if sentinel absent; reports drift on mismatch.
  check_token() {
    local token="$1" expected="$2" file="$3"
    # Skip tokens that don't exist in this file
    grep -q "<!-- ${token} -->" "$file" 2>/dev/null || return 0
    local found
    found=$(read_token "$token" "$file")
    if [[ "$found" != "$expected" ]]; then
      echo "  DRIFT: <!-- ${token} --> expected=${expected} found=${found}" >&2
      return 1
    fi
    return 0
  }

  # Check all sentinel tokens in README
  check_token "CAST_AGENT_COUNT"     "$AGENT_COUNT"     "$README" || DRIFT=1
  check_token "CAST_COMMAND_COUNT"   "$CMD_COUNT"       "$README" || DRIFT=1
  check_token "CAST_SKILL_COUNT"     "$SKILL_COUNT"     "$README" || DRIFT=1
  check_token "CAST_TEST_COUNT"      "$TEST_COUNT"      "$README" || DRIFT=1
  check_token "CAST_TEST_FILE_COUNT" "$TEST_FILE_COUNT" "$README" || DRIFT=1
  check_token "CAST_ROUTE_COUNT"     "$ROUTE_COUNT"     "$README" || DRIFT=1
  check_token "CAST_DB_TABLE_COUNT"  "$DB_TABLE_COUNT"  "$README" || DRIFT=1

  # Check shields.io badge URLs in README (only if the badge URL family is present)
  found_agents_badge=$(grep -oE '/badge/agents-[0-9]+-[a-z]+' "$README" | head -1 || true)
  if [[ -n "$found_agents_badge" ]]; then
    expected_agents_badge="/badge/agents-${AGENT_COUNT}-green"
    if [[ "$found_agents_badge" != "$expected_agents_badge" ]]; then
      echo "  DRIFT: badge agents expected='${expected_agents_badge}' found='${found_agents_badge}'" >&2
      DRIFT=1
    fi
  fi

  found_tests_badge=$(grep -oE '/badge/tests-[0-9]+-[a-z]+' "$README" | head -1 || true)
  if [[ -n "$found_tests_badge" ]]; then
    expected_tests_badge="/badge/tests-${TEST_COUNT}-brightgreen"
    if [[ "$found_tests_badge" != "$expected_tests_badge" ]]; then
      echo "  DRIFT: badge tests expected='${expected_tests_badge}' found='${found_tests_badge}'" >&2
      DRIFT=1
    fi
  fi

  if [ -f "$VERSION_FILE" ]; then
    found_version_badge=$(grep -oE '/badge/version-[0-9]+(\.[0-9]+){0,2}-[a-z]+' "$README" | head -1 || true)
    if [[ -n "$found_version_badge" ]]; then
      expected_version_badge="/badge/version-${CAST_VERSION}-blue"
      if [[ "$found_version_badge" != "$expected_version_badge" ]]; then
        echo "  DRIFT: badge version expected='${expected_version_badge}' found='${found_version_badge}'" >&2
        DRIFT=1
      fi
    fi
  fi

  # Also check docs/ sentinel files (no badge URLs there, just sentinel tokens)
  if [ -d "$REPO_DIR/docs" ]; then
    while IFS= read -r doc; do
      [ -f "$doc" ] || continue
      if grep -q "<!-- CAST_" "$doc" 2>/dev/null; then
        check_token "CAST_AGENT_COUNT"     "$AGENT_COUNT"     "$doc" || DRIFT=1
        check_token "CAST_COMMAND_COUNT"   "$CMD_COUNT"       "$doc" || DRIFT=1
        check_token "CAST_SKILL_COUNT"     "$SKILL_COUNT"     "$doc" || DRIFT=1
        check_token "CAST_TEST_COUNT"      "$TEST_COUNT"      "$doc" || DRIFT=1
        check_token "CAST_TEST_FILE_COUNT" "$TEST_FILE_COUNT" "$doc" || DRIFT=1
        check_token "CAST_ROUTE_COUNT"     "$ROUTE_COUNT"     "$doc" || DRIFT=1
        check_token "CAST_DB_TABLE_COUNT"  "$DB_TABLE_COUNT"  "$doc" || DRIFT=1
      fi
    done < <(find "$REPO_DIR/docs" -name '*.md' -type f 2>/dev/null)
  fi

  if [[ "$DRIFT" -eq 1 ]]; then
    echo "[gen-stats] DRIFT DETECTED — README sentinels or badge URLs are stale." >&2
    echo "Run: bash scripts/gen-stats.sh  to regenerate." >&2
    exit 1
  else
    echo "[gen-stats] README and docs/ sentinels are in sync." >&2
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# MUTATION MODE — update sentinel tokens and badge URLs in README (default)
# ---------------------------------------------------------------------------

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
  update_token "CAST_TEST_FILE_COUNT" "$TEST_FILE_COUNT" "$file"
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
