#!/usr/bin/env bash
# cast-cache-metrics.sh — compute prompt cache hit rate from last 30 days
#
# Purpose: Query cast.db sessions table for cache performance metrics and
# write a JSON report. Handles missing cache columns gracefully.
#
# Output:
#   - JSON report: ~/.claude/reports/cache-metrics-$(date +%Y-%m-%d).json
#   - Stdout: One-line summary with cache hit rate
#
# Monthly schedule registration (run once):
#   /schedule --description "CAST cache metrics monthly report" \
#     --command "bash ~/Projects/personal/claude-agent-team/scripts/cast-cache-metrics.sh" \
#     --frequency monthly --day-of-month 1 --time 08:00

if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# --- Config ---
CAST_DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"
REPORTS_DIR="${HOME}/.claude/reports"
REPORT_DATE=$(date +%Y-%m-%d)
REPORT_FILE="${REPORTS_DIR}/cache-metrics-${REPORT_DATE}.json"

# --- Ensure output dirs exist ---
mkdir -p "$REPORTS_DIR"

# --- Check if sessions table exists and has cache columns ---
_check_schema() {
  if ! sqlite3 "$CAST_DB_PATH" ".tables" 2>/dev/null | grep -q "sessions"; then
    return 1
  fi

  # Check for cache columns
  local columns
  columns=$(sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(sessions);" 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')
  if [[ "$columns" =~ cache_read_tokens ]] && [[ "$columns" =~ cache_write_tokens ]] && [[ "$columns" =~ input_tokens ]]; then
    return 0
  fi
  return 1
}

# --- Main logic ---
if ! _check_schema; then
  echo "WARNING: cast.db sessions table missing or lacks cache columns (cache_read_tokens, cache_write_tokens, input_tokens). Skipping cache metrics." >&2
  echo "{\"status\": \"skipped\", \"reason\": \"schema missing\"}" > "$REPORT_FILE"
  exit 0
fi

# --- Query cache metrics for last 30 days ---
QUERY="SELECT
  COALESCE(SUM(cache_read_tokens), 0) AS cache_read,
  COALESCE(SUM(cache_write_tokens), 0) AS cache_write,
  COALESCE(SUM(input_tokens), 0) AS input
FROM sessions
WHERE created_at > datetime('now', '-30 days');"

RESULT=$(sqlite3 "$CAST_DB_PATH" "$QUERY" 2>/dev/null || echo "0|0|0")

# Parse results
CACHE_READ=$(echo "$RESULT" | cut -d'|' -f1)
CACHE_WRITE=$(echo "$RESULT" | cut -d'|' -f2)
INPUT=$(echo "$RESULT" | cut -d'|' -f3)

# --- Compute cache hit rate ---
DENOMINATOR=$((INPUT + CACHE_WRITE))
CACHE_HIT_RATE="0.0"

if [[ $DENOMINATOR -gt 0 ]]; then
  # Avoid integer division: use awk for float arithmetic
  CACHE_HIT_RATE=$(awk -v read="$CACHE_READ" -v denom="$DENOMINATOR" 'BEGIN { printf "%.1f", (read / denom) * 100 }')
fi

# --- Write JSON report ---
cat > "$REPORT_FILE" << EOF
{
  "report_date": "${REPORT_DATE}",
  "period_days": 30,
  "cache_read_tokens": ${CACHE_READ},
  "cache_write_tokens": ${CACHE_WRITE},
  "input_tokens": ${INPUT},
  "cache_hit_rate_percent": ${CACHE_HIT_RATE},
  "timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
EOF

# --- Print stdout summary ---
echo "Cache hit rate (30d): ${CACHE_HIT_RATE}% (read: ${CACHE_READ} tokens, write: ${CACHE_WRITE} tokens)"

exit 0
