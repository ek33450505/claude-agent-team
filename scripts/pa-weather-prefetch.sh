#!/bin/bash
# pa-weather-prefetch.sh
# Pre-fetches weather data from NWS API and writes to jarvis repo for RemoteTrigger
# Usage: ./pa-weather-prefetch.sh

set -euo pipefail

# --- Constants ---
WEATHER_ENDPOINT="https://api.weather.gov/gridpoints/ILN/83,83/forecast"
USER_AGENT="JARVIS/1.0 (ek33450505@gmail.com)"
CURL_TIMEOUT=10
JARVIS_WEATHER_FILE="${HOME}/Projects/personal/jarvis/CAST/weather-cache.md"
LOG_FILE="${HOME}/.claude/logs/pa-weather-prefetch.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TIMESTAMP_ET=$(date '+%Y-%m-%d %H:%M %Z')

# --- Logging ---
_log() {
  echo "[${TIMESTAMP}] $*" >> "${LOG_FILE}"
}

# --- Main ---
_log "Starting weather prefetch"

# Fetch weather data
RESPONSE=$(curl -s \
  -m "${CURL_TIMEOUT}" \
  -H "User-Agent: ${USER_AGENT}" \
  "${WEATHER_ENDPOINT}" 2>&1 || echo "CURL_ERROR")

# Check for curl errors
if [[ "${RESPONSE}" == "CURL_ERROR" ]]; then
  _log "ERROR: curl failed to fetch weather data"
  FALLBACK_CONTENT="# Weather — Upper Arlington, OH
*Weather data unavailable — NWS API error at ${TIMESTAMP_ET}*"
  echo "${FALLBACK_CONTENT}" > "${JARVIS_WEATHER_FILE}"
  _log "Wrote fallback weather cache"
  exit 0
fi

# Check if response is HTML error (not JSON)
if [[ "${RESPONSE}" == "<!DOCTYPE"* ]]; then
  _log "ERROR: NWS API returned HTML error page"
  FALLBACK_CONTENT="# Weather — Upper Arlington, OH
*Weather data unavailable — NWS API error at ${TIMESTAMP_ET}*"
  echo "${FALLBACK_CONTENT}" > "${JARVIS_WEATHER_FILE}"
  _log "Wrote fallback weather cache"
  exit 0
fi

# Parse JSON and extract first 3 periods
MARKDOWN_CONTENT=$(echo "${RESPONSE}" | python3 -c '
import json, sys
from datetime import datetime

try:
    data = json.loads(sys.stdin.read())
    periods = data.get("properties", {}).get("periods", [])[:3]
    if not periods:
        print("PARSE_ERROR", end="")
        sys.exit(0)

    timestamp_et = datetime.now().strftime("%Y-%m-%d %H:%M ET")
    lines = [
        "# Weather — Upper Arlington, OH",
        f"*Last updated: {timestamp_et}*",
        ""
    ]
    for period in periods:
        name = period.get("name", "Unknown")
        temp = period.get("temperature", "N/A")
        unit = period.get("temperatureUnit", "F")
        detailed = period.get("detailedForecast", "No details available")
        wind_speed = period.get("windSpeed", "Calm")
        wind_dir = period.get("windDirection", "--")
        precip = period.get("probabilityOfPrecipitation", {}).get("value") or 0
        lines.append(f"## {name} — {temp}\u00b0{unit}")
        lines.append(detailed)
        lines.append(f"- Wind: {wind_speed} {wind_dir}")
        lines.append(f"- Precipitation: {precip}%")
        lines.append("")
    print("\n".join(lines), end="")
except Exception:
    print("PARSE_ERROR", end="")
' 2>/dev/null || echo "PARSE_ERROR")

# Check if Python parsing failed
if [[ "${MARKDOWN_CONTENT}" == "PARSE_ERROR" ]]; then
  _log "ERROR: Python JSON parsing failed"
  FALLBACK_CONTENT="# Weather — Upper Arlington, OH
*Weather data unavailable — NWS API error at ${TIMESTAMP_ET}*"
  echo "${FALLBACK_CONTENT}" > "${JARVIS_WEATHER_FILE}"
  _log "Wrote fallback weather cache"
  exit 0
fi

# Write markdown to jarvis repo
echo "${MARKDOWN_CONTENT}" > "${JARVIS_WEATHER_FILE}"
_log "Wrote weather cache to ${JARVIS_WEATHER_FILE}"

# Commit and push to jarvis repo
(
  cd "${HOME}/Projects/personal/jarvis" || exit 1
  git add CAST/weather-cache.md 2>/dev/null || true
  git commit -m "chore: update weather cache" --allow-empty-message 2>/dev/null || true
  git push origin main 2>/dev/null || true
) && _log "Committed and pushed to jarvis repo" || _log "WARNING: git operations failed (may be offline)"

_log "Weather prefetch complete"
