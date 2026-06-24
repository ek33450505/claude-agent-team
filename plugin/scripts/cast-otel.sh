#!/bin/bash
# cast-otel.sh — control surface for CAST OpenTelemetry collector daemon
# Subcommands: enable | disable | status | start | stop

set -euo pipefail

# Configuration
readonly PLIST_LABEL="com.cast.otel-collector"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
readonly SETTINGS_JSON="${CAST_SETTINGS_JSON:-${HOME}/.claude/settings.json}"
readonly DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
readonly LAUNCHCTL="${CAST_OTEL_LAUNCHCTL_CMD:-launchctl}"

# For testing: allow dry-run via env var
readonly DRY_RUN="${CAST_OTEL_DRY_RUN:-0}"

# 5 telemetry env keys
readonly TELEMETRY_KEYS=(
  "CLAUDE_CODE_ENABLE_TELEMETRY"
  "OTEL_METRICS_EXPORTER"
  "OTEL_LOGS_EXPORTER"
  "OTEL_EXPORTER_OTLP_PROTOCOL"
  "OTEL_EXPORTER_OTLP_ENDPOINT"
)

readonly TELEMETRY_VALUES=(
  "1"
  "otlp"
  "otlp"
  "http/json"
  "http://localhost:4318"
)

# ============================================================================
# JSON mutation helpers (python)
# ============================================================================

# Add or update telemetry keys in settings.json (via env vars)
_ensure_env_vars() {
  local settings_path="$1"
  shift

  # Build pipe-delimited K=V pairs from remaining args (key, value, key, value, ...)
  local pairs=""
  while [[ $# -gt 1 ]]; do
    local key="$1"
    local val="$2"
    shift 2
    pairs+="${key}=${val}"
    if [[ $# -gt 1 ]]; then
      pairs+="|"
    fi
  done

  _CAST_SETTINGS_PATH="${settings_path}" \
  _CAST_ENV_KEYS="${pairs}" \
  python3 << 'PYEOF'
import json
import os
import sys

settings_path = os.environ.get('_CAST_SETTINGS_PATH')
keys_str = os.environ.get('_CAST_ENV_KEYS', '')

if not keys_str:
    sys.exit(0)

# Parse key-value pairs from env var (pipe-delimited K=V pairs)
env_dict = {}
for pair in keys_str.split('|'):
  if '=' in pair:
    k, v = pair.split('=', 1)
    env_dict[k] = v

try:
  if os.path.exists(settings_path):
    with open(settings_path, 'r') as f:
      data = json.load(f)
  else:
    data = {}

  if 'env' not in data:
    data['env'] = {}

  # Only add keys that don't already exist
  for key, val in env_dict.items():
    if key not in data['env']:
      data['env'][key] = val

  with open(settings_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

except Exception as e:
  print(f"Error updating settings.json: {e}", file=sys.stderr)
  sys.exit(1)
PYEOF
}

# Remove telemetry keys from settings.json (preserve other env keys)
_remove_env_vars() {
  local settings_path="$1"
  shift
  local keys="$@"

  _CAST_SETTINGS_PATH="${settings_path}" \
  _CAST_KEYS_TO_REMOVE="${keys}" \
  python3 << 'PYEOF'
import json
import os
import sys

settings_path = os.environ.get('_CAST_SETTINGS_PATH')
keys_str = os.environ.get('_CAST_KEYS_TO_REMOVE', '')

if not keys_str:
    sys.exit(0)

keys_to_remove = keys_str.split()

try:
  if not os.path.exists(settings_path):
    sys.exit(0)

  with open(settings_path, 'r') as f:
    data = json.load(f)

  if 'env' not in data:
    sys.exit(0)

  # Remove only the specified keys
  for key in keys_to_remove:
    data['env'].pop(key, None)

  with open(settings_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

except Exception as e:
  print(f"Error updating settings.json: {e}", file=sys.stderr)
  sys.exit(1)
PYEOF
}

# Check if telemetry env keys are present in settings.json
_check_env_vars() {
  local settings_path="$1"
  shift
  local keys="$@"

  _CAST_SETTINGS_PATH="${settings_path}" \
  _CAST_KEYS_TO_CHECK="${keys}" \
  python3 << 'PYEOF'
import json
import os
import sys

settings_path = os.environ.get('_CAST_SETTINGS_PATH')
keys_str = os.environ.get('_CAST_KEYS_TO_CHECK', '')

if not keys_str:
    print("0")
    sys.exit(0)

keys_to_check = keys_str.split()

try:
  if not os.path.exists(settings_path):
    print("0")
    sys.exit(0)

  with open(settings_path, 'r') as f:
    data = json.load(f)

  if 'env' not in data:
    print("0")
    sys.exit(0)

  count = sum(1 for key in keys_to_check if key in data['env'])
  print(str(count))

except Exception:
  print("0")
PYEOF
}

# ============================================================================
# Subcommands
# ============================================================================

_enable() {
  echo "Enabling CAST OpenTelemetry collector..."

  # Guard launchctl for test mode
  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ ! -f "${PLIST_PATH}" ]]; then
      echo "Error: plist not found at ${PLIST_PATH}" >&2
      echo "Run 'bash install.sh' to install the plist." >&2
      return 1
    fi

    # Load the plist
    "${LAUNCHCTL}" load "${PLIST_PATH}" 2>/dev/null || true
  else
    echo "[DRY RUN] would load: ${LAUNCHCTL} load ${PLIST_PATH}"
  fi

  # Add telemetry env keys to settings.json
  _ensure_env_vars "${SETTINGS_JSON}" \
    "${TELEMETRY_KEYS[0]}" "${TELEMETRY_VALUES[0]}" \
    "${TELEMETRY_KEYS[1]}" "${TELEMETRY_VALUES[1]}" \
    "${TELEMETRY_KEYS[2]}" "${TELEMETRY_VALUES[2]}" \
    "${TELEMETRY_KEYS[3]}" "${TELEMETRY_VALUES[3]}" \
    "${TELEMETRY_KEYS[4]}" "${TELEMETRY_VALUES[4]}"

  echo "Restart Claude Code sessions for telemetry to take effect."
}

_disable() {
  echo "Disabling CAST OpenTelemetry collector..."

  # Remove telemetry env keys from settings.json
  _remove_env_vars "${SETTINGS_JSON}" "${TELEMETRY_KEYS[@]}"

  # Unload the plist
  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ -f "${PLIST_PATH}" ]]; then
      "${LAUNCHCTL}" unload "${PLIST_PATH}" 2>/dev/null || true
    fi
  else
    echo "[DRY RUN] would unload: ${LAUNCHCTL} unload ${PLIST_PATH}"
  fi

  echo "OTEL collector disabled."
}

_status() {
  echo "=== CAST OpenTelemetry Collector Status ==="
  echo ""

  # (1) Daemon status
  echo "Daemon status:"
  if command -v launchctl >/dev/null 2>&1; then
    if "${LAUNCHCTL}" list "${PLIST_LABEL}" >/dev/null 2>&1; then
      echo "  ✓ Loaded"
    else
      echo "  ✗ Not loaded"
    fi
  else
    echo "  ⊘ launchctl not available (Linux/CI)"
  fi

  # Check process
  if pgrep -qf "cast-otel-collector.py"; then
    echo "  ✓ Process running"
  else
    echo "  ✗ Process not running"
  fi

  echo ""

  # (2) Telemetry env keys
  echo "Environment keys in settings.json:"
  local env_count
  env_count=$(_check_env_vars "${SETTINGS_JSON}" "${TELEMETRY_KEYS[@]}")
  local total_keys="${#TELEMETRY_KEYS[@]}"
  if [[ "${env_count}" == "${total_keys}" ]]; then
    echo "  ✓ All ${total_keys} telemetry keys present"
  elif [[ "${env_count}" == "0" ]]; then
    echo "  ✗ No telemetry keys found"
  else
    echo "  ⚠ ${env_count}/${total_keys} telemetry keys present"
  fi

  echo ""

  # (3) Database row counts
  echo "Database metrics:"
  if [[ -f "${DB_PATH}" ]]; then
    local otel_metrics_count
    local otel_events_count

    # Query otel_metrics table
    if otel_metrics_count=$(sqlite3 "${DB_PATH}" "SELECT COUNT(*) FROM otel_metrics" 2>/dev/null); then
      echo "  otel_metrics: ${otel_metrics_count} rows"
    else
      echo "  otel_metrics: table not found"
    fi

    # Query otel_events table
    if otel_events_count=$(sqlite3 "${DB_PATH}" "SELECT COUNT(*) FROM otel_events" 2>/dev/null); then
      echo "  otel_events: ${otel_events_count} rows"
    else
      echo "  otel_events: table not found"
    fi
  else
    echo "  Database not found at ${DB_PATH}"
  fi
}

_start() {
  echo "Starting CAST OpenTelemetry collector daemon..."

  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ ! -f "${PLIST_PATH}" ]]; then
      echo "Error: plist not found at ${PLIST_PATH}" >&2
      return 1
    fi
    "${LAUNCHCTL}" load "${PLIST_PATH}" 2>/dev/null || true
  else
    echo "[DRY RUN] would load: ${LAUNCHCTL} load ${PLIST_PATH}"
  fi
}

_stop() {
  echo "Stopping CAST OpenTelemetry collector daemon..."

  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ -f "${PLIST_PATH}" ]]; then
      "${LAUNCHCTL}" unload "${PLIST_PATH}" 2>/dev/null || true
    fi
  else
    echo "[DRY RUN] would unload: ${LAUNCHCTL} unload ${PLIST_PATH}"
  fi
}

# ============================================================================
# Main
# ============================================================================

main() {
  local cmd="${1:-}"

  case "${cmd}" in
    enable)
      _enable
      ;;
    disable)
      _disable
      ;;
    status)
      _status
      ;;
    start)
      _start
      ;;
    stop)
      _stop
      ;;
    *)
      cat << 'EOF'
Usage: cast-otel.sh <subcommand>

Subcommands:
  enable    Enable OTEL collector daemon and set telemetry env keys
  disable   Disable OTEL collector daemon and remove telemetry env keys
  status    Show daemon status, env keys, and row counts
  start     Start the daemon (launchctl load only, no settings.json mutation)
  stop      Stop the daemon (launchctl unload only, no settings.json mutation)

Environment overrides:
  CAST_SETTINGS_JSON     Path to settings.json (default: ~/.claude/settings.json)
  CAST_DB_PATH           Path to cast.db (default: ~/.claude/cast.db)
  CAST_OTEL_DRY_RUN      If set to "1", skip launchctl calls (for testing)
  CAST_OTEL_LAUNCHCTL_CMD Override launchctl binary (for testing)
EOF
      return 1
      ;;
  esac
}

main "$@"
