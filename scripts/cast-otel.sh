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

# Fragment path — the durable source of truth for env keys (survives reinstall)
# Defaults to 12-otel.json (the dedicated telemetry fragment); CAST_OTEL_FRAGMENT overrides.
readonly CLAUDE_DIR="${CAST_CLAUDE_DIR:-${HOME}/.claude}"
readonly FRAGMENT_PATH="${CAST_OTEL_FRAGMENT:-${CLAUDE_DIR}/managed-settings.d/12-otel.json}"
readonly MERGE_SCRIPT="${CLAUDE_DIR}/scripts/cast-merge-settings.sh"

# For testing: allow dry-run via env var
readonly DRY_RUN="${CAST_OTEL_DRY_RUN:-0}"

# 5 telemetry env keys managed by enable/disable (does NOT include DISABLE_TELEMETRY —
# DISABLE_TELEMETRY lives in the personal overlay, managed-settings-personal/12-otel.json,
# and is set for the maintainer only; it is NOT added by cast-otel.sh enable)
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
# Fragment JSON mutation helpers (python)
# ============================================================================

# Add or update telemetry keys in the managed-settings.d fragment (durable source of truth).
# Falls back to settings.json mutation if the fragment does not exist.
_ensure_env_vars_in_fragment() {
  local fragment_path="$1"
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

  _CAST_FRAGMENT_PATH="${fragment_path}" \
  _CAST_ENV_KEYS="${pairs}" \
  python3 << 'PYEOF'
import json
import os
import sys

fragment_path = os.environ.get('_CAST_FRAGMENT_PATH')
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
  if fragment_path and os.path.exists(fragment_path):
    with open(fragment_path, 'r') as f:
      data = json.load(f)
  else:
    data = {}

  if 'env' not in data:
    data['env'] = {}

  # Add or overwrite keys
  for key, val in env_dict.items():
    data['env'][key] = val

  if fragment_path:
    with open(fragment_path, 'w') as f:
      json.dump(data, f, indent=2)
      f.write('\n')

except Exception as e:
  print(f"Error updating fragment: {e}", file=sys.stderr)
  sys.exit(1)
PYEOF
}

# Remove telemetry keys from the managed-settings.d fragment (preserve other env keys).
_remove_env_vars_from_fragment() {
  local fragment_path="$1"
  shift
  local keys="$*"

  _CAST_FRAGMENT_PATH="${fragment_path}" \
  _CAST_KEYS_TO_REMOVE="${keys}" \
  python3 << 'PYEOF'
import json
import os
import sys

fragment_path = os.environ.get('_CAST_FRAGMENT_PATH')
keys_str = os.environ.get('_CAST_KEYS_TO_REMOVE', '')

if not keys_str:
    sys.exit(0)

keys_to_remove = keys_str.split()

try:
  if not fragment_path or not os.path.exists(fragment_path):
    sys.exit(0)

  with open(fragment_path, 'r') as f:
    data = json.load(f)

  if 'env' not in data:
    sys.exit(0)

  # Remove only the specified keys (leave everything else including DISABLE_TELEMETRY)
  for key in keys_to_remove:
    data['env'].pop(key, None)

  with open(fragment_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

except Exception as e:
  print(f"Error updating fragment: {e}", file=sys.stderr)
  sys.exit(1)
PYEOF
}

# Check if telemetry env keys are present in the fragment
_check_env_vars_in_fragment() {
  local fragment_path="$1"
  shift
  local keys="$*"

  _CAST_FRAGMENT_PATH="${fragment_path}" \
  _CAST_KEYS_TO_CHECK="${keys}" \
  python3 << 'PYEOF'
import json
import os
import sys

fragment_path = os.environ.get('_CAST_FRAGMENT_PATH')
keys_str = os.environ.get('_CAST_KEYS_TO_CHECK', '')

if not keys_str:
    print("0")
    sys.exit(0)

keys_to_check = keys_str.split()

try:
  if not fragment_path or not os.path.exists(fragment_path):
    print("0")
    sys.exit(0)

  with open(fragment_path, 'r') as f:
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

# Backward-compat: check settings.json directly (used by status when fragment absent)
_check_env_vars() {
  local settings_path="$1"
  shift
  local keys="$*"

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
  if not settings_path or not os.path.exists(settings_path):
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

# Regenerate settings.json from fragments (durable merge step)
_regenerate_settings() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DRY RUN] would regenerate settings.json via cast-merge-settings.sh"
    return 0
  fi
  if [[ -f "${MERGE_SCRIPT}" ]]; then
    bash "${MERGE_SCRIPT}" "${SETTINGS_JSON}" 2>/dev/null || true
  fi
}

# ============================================================================
# Subcommands
# ============================================================================

_enable() {
  echo "Enabling CAST OpenTelemetry collector..."

  # Ensure telemetry env keys are present in the fragment (durable — survives reinstall)
  _ensure_env_vars_in_fragment "${FRAGMENT_PATH}" \
    "${TELEMETRY_KEYS[0]}" "${TELEMETRY_VALUES[0]}" \
    "${TELEMETRY_KEYS[1]}" "${TELEMETRY_VALUES[1]}" \
    "${TELEMETRY_KEYS[2]}" "${TELEMETRY_VALUES[2]}" \
    "${TELEMETRY_KEYS[3]}" "${TELEMETRY_VALUES[3]}" \
    "${TELEMETRY_KEYS[4]}" "${TELEMETRY_VALUES[4]}"

  # Secure the fragment (may contain env keys) — matches install.sh chmod 600 on personal overlays
  chmod 600 "${FRAGMENT_PATH}" 2>/dev/null || true

  # Regenerate settings.json from fragments
  _regenerate_settings

  # Guard launchctl and PlistBuddy for test mode
  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ ! -f "${PLIST_PATH}" ]]; then
      echo "Error: plist not found at ${PLIST_PATH}" >&2
      echo "Run 'bash install.sh' to install the plist." >&2
      return 1
    fi

    # Set RunAtLoad=true so the daemon persists across reboots
    /usr/libexec/PlistBuddy -c "Set :RunAtLoad true" "${PLIST_PATH}" 2>/dev/null || true

    # Load the plist (starts the daemon now)
    "${LAUNCHCTL}" load "${PLIST_PATH}" 2>/dev/null || true
  else
    echo "[DRY RUN] would set RunAtLoad true in ${PLIST_PATH}"
    echo "[DRY RUN] would load: ${LAUNCHCTL} load ${PLIST_PATH}"
  fi

  echo "Restart Claude Code sessions for telemetry to take effect."
}

_disable() {
  echo "Disabling CAST OpenTelemetry collector..."

  # Remove telemetry env keys from the fragment (leave DISABLE_TELEMETRY intact)
  _remove_env_vars_from_fragment "${FRAGMENT_PATH}" "${TELEMETRY_KEYS[@]}"

  # Regenerate settings.json from fragments
  _regenerate_settings

  # Unload the plist and set RunAtLoad=false so it stays dormant across reboots
  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ -f "${PLIST_PATH}" ]]; then
      "${LAUNCHCTL}" unload "${PLIST_PATH}" 2>/dev/null || true
      # Keep plist dormant across reboots (install.sh ships RunAtLoad=false; restore it here)
      /usr/libexec/PlistBuddy -c "Set :RunAtLoad false" "${PLIST_PATH}" 2>/dev/null || true
    fi
  else
    echo "[DRY RUN] would unload: ${LAUNCHCTL} unload ${PLIST_PATH}"
    echo "[DRY RUN] would set RunAtLoad false in ${PLIST_PATH}"
  fi

  echo "OTEL collector disabled. Run 'cast-otel.sh enable' to re-enable."
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

  # (2) Telemetry env keys — check fragment first, fall back to settings.json
  echo "Environment keys:"
  local env_count
  local total_keys="${#TELEMETRY_KEYS[@]}"

  if [[ -f "${FRAGMENT_PATH}" ]]; then
    env_count=$(_check_env_vars_in_fragment "${FRAGMENT_PATH}" "${TELEMETRY_KEYS[@]}")
    echo "  Source: fragment (${FRAGMENT_PATH})"
  else
    env_count=$(_check_env_vars "${SETTINGS_JSON}" "${TELEMETRY_KEYS[@]}")
    echo "  Source: settings.json (fragment not found)"
  fi

  if [[ "${env_count}" == "${total_keys}" ]]; then
    echo "  ✓ All ${total_keys} telemetry keys present"
  elif [[ "${env_count}" == "0" ]]; then
    echo "  ✗ No telemetry keys found (run 'cast-otel.sh enable' to activate)"
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
  enable    Ensure telemetry keys in fragment + regenerate settings.json + load daemon
  disable   Remove telemetry keys from fragment + regenerate settings.json + unload daemon
  status    Show daemon status, env keys (fragment-first), and row counts
  start     Start the daemon (launchctl load only, no settings.json mutation)
  stop      Stop the daemon (launchctl unload only, no settings.json mutation)

Environment overrides:
  CAST_SETTINGS_JSON       Path to settings.json (default: ~/.claude/settings.json)
  CAST_OTEL_FRAGMENT       Path to telemetry fragment (default: ~/.claude/managed-settings.d/12-otel.json)
  CAST_CLAUDE_DIR          Path to ~/.claude dir (default: $HOME/.claude)
  CAST_DB_PATH             Path to cast.db (default: ~/.claude/cast.db)
  CAST_OTEL_DRY_RUN        If set to "1", skip launchctl calls (for testing)
  CAST_OTEL_LAUNCHCTL_CMD  Override launchctl binary (for testing)
EOF
      return 1
      ;;
  esac
}

main "$@"
