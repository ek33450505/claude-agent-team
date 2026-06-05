#!/usr/bin/env bash
# cast-stats-drift-check.sh — Verify consuming-repo stats match canonical flagship JSON.
#
# Run from a consuming repo's checkout directory. Exits 1 on any mismatch.
#
# Usage:
#   bash cast-stats-drift-check.sh [options]
#
# Options:
#   --canonical <url-or-path>   Source of truth. If it looks like a URL (starts with
#                               http:// or https://), fetch with curl -fsSL; else cat.
#                               Default: https://raw.githubusercontent.com/ek33450505/
#                                        claude-agent-team/main/cast-stats.json
#   --json <path>               A local JSON file to compare (repeatable).
#                               Compared stat fields: version, agents, tests, tables,
#                               commands, skills, packages.
#                               version matches if equal to canonical 'version' OR 'versionTag'.
#   --sentinels <path>          A text/md file with <!-- TOKEN -->value<!-- /TOKEN --> sentinels.
#                               Compared mappings:
#                                 CAST_VERSION    -> version  (v-prefix accepted)
#                                 CAST_AGENT_COUNT-> agents
#                                 CAST_TEST_COUNT -> tests
#                                 CAST_DB_TABLE_COUNT -> tables
#                                 CAST_COMMAND_COUNT  -> commands
#                                 CAST_SKILL_COUNT    -> skills
#                               Tokens absent from the file are skipped (not an error).
#
# Exit codes: 0 = all checks passed, 1 = one or more mismatches or fetch error.

set -euo pipefail

DEFAULT_CANONICAL="https://raw.githubusercontent.com/ek33450505/claude-agent-team/main/cast-stats.json"

CANONICAL_SRC=""
JSON_FILES=()
SENTINEL_FILES=()

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --canonical)
      CANONICAL_SRC="$2"; shift 2 ;;
    --json)
      JSON_FILES+=("$2"); shift 2 ;;
    --sentinels)
      SENTINEL_FILES+=("$2"); shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

CANONICAL_SRC="${CANONICAL_SRC:-$DEFAULT_CANONICAL}"

# --- Auto-discovery (kicks in only when neither --json nor --sentinels was passed) ---
if [[ ${#JSON_FILES[@]} -eq 0 && ${#SENTINEL_FILES[@]} -eq 0 ]]; then
  # Candidate JSON paths (order: most common first)
  for _candidate_json in "cast-stats.json" "public/cast-stats.json" "src/data/cast-stats.json"; do
    if [[ -f "$_candidate_json" ]]; then
      JSON_FILES+=("$_candidate_json")
    fi
  done

  # README.md if it contains a <!-- CAST_ token
  if [[ -f "README.md" ]] && grep -q '<!-- CAST_' "README.md" 2>/dev/null; then
    SENTINEL_FILES+=("README.md")
  fi

  # docs/**/*.md that contain a <!-- CAST_ token (guarded for missing docs/)
  if [[ -d "docs" ]]; then
    while IFS= read -r _doc; do
      if [[ -f "$_doc" ]] && grep -q '<!-- CAST_' "$_doc" 2>/dev/null; then
        SENTINEL_FILES+=("$_doc")
      fi
    done < <(find docs -name '*.md' -type f 2>/dev/null)
  fi

  # If still nothing found, safe no-op
  if [[ ${#JSON_FILES[@]} -eq 0 && ${#SENTINEL_FILES[@]} -eq 0 ]]; then
    echo "[drift-check] no CAST stat markers found — nothing to check"
    exit 0
  fi
fi

# --- Fetch canonical ---
fetch_canonical() {
  local src="$1"
  if [[ "$src" == http://* || "$src" == https://* ]]; then
    if ! curl -fsSL "$src"; then
      echo "[cast-stats-drift-check] ERROR: could not fetch canonical from: $src" >&2
      exit 1
    fi
  else
    if [[ ! -f "$src" ]]; then
      echo "[cast-stats-drift-check] ERROR: canonical file not found: $src" >&2
      exit 1
    fi
    cat "$src"
  fi
}

CANONICAL_JSON="$(fetch_canonical "$CANONICAL_SRC")"

# Validate canonical is parseable JSON
if ! echo "$CANONICAL_JSON" | jq empty 2>/dev/null; then
  echo "[cast-stats-drift-check] ERROR: canonical source is not valid JSON" >&2
  exit 1
fi

# Extract canonical values
C_VERSION="$(echo "$CANONICAL_JSON" | jq -r '.version')"
C_VERSION_TAG="$(echo "$CANONICAL_JSON" | jq -r '.versionTag')"
C_AGENTS="$(echo "$CANONICAL_JSON" | jq -r '.agents')"
C_TESTS="$(echo "$CANONICAL_JSON" | jq -r '.tests')"
C_TABLES="$(echo "$CANONICAL_JSON" | jq -r '.tables')"
C_COMMANDS="$(echo "$CANONICAL_JSON" | jq -r '.commands')"
C_SKILLS="$(echo "$CANONICAL_JSON" | jq -r '.skills')"
C_PACKAGES="$(echo "$CANONICAL_JSON" | jq -r '.packages')"

FAIL_COUNT=0

check_field() {
  local source="$1" field="$2" expected="$3" found="$4"
  if [[ "$found" == "$expected" ]]; then
    echo "  PASS  $field: $found  (source: $source)"
  else
    echo "  FAIL  $field: expected=$expected found=$found  (source: $source)"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
}

# --- Check JSON files ---
for json_file in "${JSON_FILES[@]}"; do
  if [[ ! -f "$json_file" ]]; then
    echo "[cast-stats-drift-check] ERROR: --json file not found: $json_file" >&2
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    continue
  fi

  echo "Checking JSON: $json_file"
  LOCAL_JSON="$(cat "$json_file")"

  # version: accept matching either canonical version or versionTag
  LOCAL_VERSION="$(echo "$LOCAL_JSON" | jq -r '.version // empty')"
  if [[ "$LOCAL_VERSION" == "$C_VERSION" || "$LOCAL_VERSION" == "$C_VERSION_TAG" ]]; then
    echo "  PASS  version: $LOCAL_VERSION  (source: $json_file)"
  else
    echo "  FAIL  version: expected=${C_VERSION} or ${C_VERSION_TAG} found=${LOCAL_VERSION}  (source: $json_file)"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi

  check_field "$json_file" "agents"   "$C_AGENTS"   "$(echo "$LOCAL_JSON" | jq -r '.agents   // empty')"
  check_field "$json_file" "tests"    "$C_TESTS"    "$(echo "$LOCAL_JSON" | jq -r '.tests    // empty')"
  check_field "$json_file" "tables"   "$C_TABLES"   "$(echo "$LOCAL_JSON" | jq -r '.tables   // empty')"
  check_field "$json_file" "commands" "$C_COMMANDS" "$(echo "$LOCAL_JSON" | jq -r '.commands // empty')"
  check_field "$json_file" "skills"   "$C_SKILLS"   "$(echo "$LOCAL_JSON" | jq -r '.skills   // empty')"
  check_field "$json_file" "packages" "$C_PACKAGES" "$(echo "$LOCAL_JSON" | jq -r '.packages // empty')"
done

# Token -> canonical field mappings
declare -A TOKEN_FIELD_MAP
TOKEN_FIELD_MAP=(
  [CAST_VERSION]="version"
  [CAST_AGENT_COUNT]="agents"
  [CAST_TEST_COUNT]="tests"
  [CAST_DB_TABLE_COUNT]="tables"
  [CAST_COMMAND_COUNT]="commands"
  [CAST_SKILL_COUNT]="skills"
)

# --- Check sentinel files ---
for sentinel_file in "${SENTINEL_FILES[@]}"; do
  if [[ ! -f "$sentinel_file" ]]; then
    echo "[cast-stats-drift-check] ERROR: --sentinels file not found: $sentinel_file" >&2
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    continue
  fi

  echo "Checking sentinels: $sentinel_file"
  FILE_CONTENT="$(cat "$sentinel_file")"

  for token in "${!TOKEN_FIELD_MAP[@]}"; do
    field="${TOKEN_FIELD_MAP[$token]}"

    # Extract sentinel value: <!-- TOKEN -->value<!-- /TOKEN -->
    # Use grep + sed; if token not present, skip (not an error)
    if ! echo "$FILE_CONTENT" | grep -qE "<!-- ${token} -->"; then
      continue
    fi

    sentinel_value="$(echo "$FILE_CONTENT" | grep -oE "<!-- ${token} -->[^<]*<!-- /${token} -->" | sed -E "s|<!-- ${token} -->||;s|<!-- /${token} -->||" | head -1)"

    # Determine expected canonical value for this field
    case "$field" in
      version)
        expected_raw="$C_VERSION"
        # Accept v-prefixed: strip leading 'v' from sentinel value for comparison
        sentinel_stripped="${sentinel_value#v}"
        if [[ "$sentinel_stripped" == "$C_VERSION" || "$sentinel_value" == "$C_VERSION" || "$sentinel_value" == "$C_VERSION_TAG" ]]; then
          echo "  PASS  ${token} -> ${field}: $sentinel_value  (source: $sentinel_file)"
        else
          echo "  FAIL  ${token} -> ${field}: expected=${C_VERSION} found=${sentinel_value}  (source: $sentinel_file)"
          FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        fi
        continue
        ;;
      agents)   expected_raw="$C_AGENTS" ;;
      tests)    expected_raw="$C_TESTS" ;;
      tables)   expected_raw="$C_TABLES" ;;
      commands) expected_raw="$C_COMMANDS" ;;
      skills)   expected_raw="$C_SKILLS" ;;
      *)        expected_raw="" ;;
    esac

    check_field "$sentinel_file" "${token} -> ${field}" "$expected_raw" "$sentinel_value"
  done
done

# --- Summary ---
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo ""
  echo "[cast-stats-drift-check] All checks PASSED."
  exit 0
else
  echo ""
  echo "[cast-stats-drift-check] FAILED: $FAIL_COUNT check(s) did not pass. Update stats to match canonical."
  exit 1
fi
