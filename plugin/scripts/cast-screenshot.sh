#!/bin/bash
# cast-screenshot.sh — Visual capture for frontend-qa via Playwright/Puppeteer
# Usage: cast-screenshot.sh <url> <output-path.png> [--wait 2000]
# Logs each capture to ~/.claude/logs/screenshot.log

# CAST subprocess guard — exit silently if running as subagent
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# Logging function
_log_screenshot() {
  local level="$1"
  local msg="$2"
  local log_file="$HOME/.claude/logs/screenshot.log"

  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

  printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg" >> "$log_file" 2>/dev/null || true
}

# Parse arguments
URL="${1:-}"
OUTPUT_PATH="${2:-}"

if [[ -z "$URL" || -z "$OUTPUT_PATH" ]]; then
  echo "Usage: cast-screenshot.sh <url> <output-path.png> [--wait 2000]" >&2
  exit 1
fi

# Optional --wait parameter (reserved for future use with navigation polling)
if [[ $# -ge 3 && "$3" == "--wait" && $# -ge 4 ]]; then
  : # $4 holds wait time — reserved for future custom wait logic
fi

# Try playwright first, fall back to puppeteer
BROWSER_TOOL=""
if npx playwright --version >/dev/null 2>&1; then
  BROWSER_TOOL="playwright"
elif npx puppeteer --version >/dev/null 2>&1; then
  BROWSER_TOOL="puppeteer"
else
  _log_screenshot "ERROR" "Neither playwright nor puppeteer found. Install with: npm install -g playwright or npm install -g puppeteer"
  echo "Error: Neither Playwright nor Puppeteer is installed. Install with: npm install -g playwright or npm install -g puppeteer" >&2
  exit 1
fi

# Ensure output directory exists
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR" 2>/dev/null || true

# Capture screenshot
if [[ "$BROWSER_TOOL" == "playwright" ]]; then
  if ! npx playwright screenshot --url "$URL" --path "$OUTPUT_PATH" --viewport-size 1280 800 --wait-for-load-state networkidle 2>/dev/null; then
    _log_screenshot "ERROR" "Playwright screenshot failed for $URL"
    echo "Error: Playwright screenshot failed. Is the dev server running at $URL?" >&2
    exit 1
  fi
else
  # Puppeteer fallback
  if ! npx puppeteer screenshot --url "$URL" --path "$OUTPUT_PATH" --viewport-width 1280 --viewport-height 800 2>/dev/null; then
    _log_screenshot "ERROR" "Puppeteer screenshot failed for $URL"
    echo "Error: Puppeteer screenshot failed. Is the dev server running at $URL?" >&2
    exit 1
  fi
fi

_log_screenshot "INFO" "Screenshot captured: $OUTPUT_PATH from $URL (tool: $BROWSER_TOOL)"
echo "$OUTPUT_PATH"
exit 0
