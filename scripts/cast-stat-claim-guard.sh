#!/bin/bash
# cast-stat-claim-guard.sh — PreToolUse hook for stat-claim verification
# Blocks README.md writes/edits when badge test count differs from actual git ls-files count.
# Prevents false badge claims from being committed.
# Exit codes: 0 = allow, 2 = block (wrong count)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

LOG_FILE="${HOME}/.claude/logs/stat-guard.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Parse JSON fields using Python (read from stdin once, then pass via env var)
INPUT="$(cat 2>/dev/null || true)"
export CAST_SGC_INPUT="$INPUT"

TOOL="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_SGC_INPUT','{}') or '{}'); print(d.get('tool_name',''))" 2>/dev/null || echo "")"
FILE_PATH="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_SGC_INPUT','{}') or '{}'); ti=d.get('tool_input',{}) or {}; print(ti.get('file_path', ti.get('path','')))" 2>/dev/null || echo "")"
CONTENT="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_SGC_INPUT','{}') or '{}'); ti=d.get('tool_input',{}) or {}; print(ti.get('content', ti.get('new_string','')))" 2>/dev/null || echo "")"

# Only trigger on Write/Edit tools targeting README.md
if [[ ! "$TOOL" =~ ^(Write|Edit)$ ]] || [[ ! "$FILE_PATH" =~ README\.md$ ]]; then
  exit 0
fi

# Check if content contains a badge pattern (tests-NUMBER or similar)
if ! echo "$CONTENT" | grep -qiE "tests-[0-9]+|badge.*test.*[0-9]+" ; then
  exit 0
fi

# Get the actual test count from git ls-files by counting @test annotations
# (matches the method in gen-stats.sh lines 24-30)
TEST_FILES=$(git ls-files 'tests/*.bats' 'tests/*/*.bats' 2>/dev/null || echo "")
if [ -n "$TEST_FILES" ]; then
  REAL_COUNT=$(echo "$TEST_FILES" | xargs grep -h "^@test" 2>/dev/null | wc -l | tr -d ' ')
else
  REAL_COUNT=0
fi

# Extract the claimed count from the badge string (pattern: tests-(\d+)-)
CLAIMED_COUNT=$(echo "$CONTENT" | grep -oE "tests-[0-9]+" | head -1 | sed 's/tests-//' || echo "")

# If we couldn't extract a claimed count, allow it to proceed
if [[ -z "$CLAIMED_COUNT" ]]; then
  exit 0
fi

# Log the check attempt
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Stat claim check: claimed=$CLAIMED_COUNT, actual=$REAL_COUNT" >> "$LOG_FILE" 2>/dev/null || true

# If counts match, allow
if [[ "$CLAIMED_COUNT" == "$REAL_COUNT" ]]; then
  exit 0
fi

# Counts differ — block and explain
DIFF=$((CLAIMED_COUNT - REAL_COUNT))
echo "[CAST STAT GUARD] Badge claims $CLAIMED_COUNT tests but actual @test count is $REAL_COUNT. Difference: $DIFF. Update the badge before proceeding. (See: feedback_bats_count_method.md)" >&2
exit 2
