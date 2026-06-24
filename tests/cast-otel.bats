#!/usr/bin/env bats
# cast-otel.bats — BATS tests for cast-otel.sh
#
# Tests the control surface (enable/disable/status) for the CAST OpenTelemetry
# collector daemon, focusing on settings.json mutation and env key management.
#
# All tests use an isolated temp HOME, temp settings.json, and stub launchctl/pgrep
# to avoid any real daemon/system interactions.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
OTEL_SH="$REPO_DIR/scripts/cast-otel.sh"

# The 5 telemetry keys that should be managed
TELEMETRY_KEYS=(
  "CLAUDE_CODE_ENABLE_TELEMETRY"
  "OTEL_METRICS_EXPORTER"
  "OTEL_LOGS_EXPORTER"
  "OTEL_EXPORTER_OTLP_PROTOCOL"
  "OTEL_EXPORTER_OTLP_ENDPOINT"
)

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Temp settings.json
  export SETTINGS_FILE="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$SETTINGS_FILE")"

  # Initialize empty settings.json
  echo '{}' > "$SETTINGS_FILE"

  # Stub launchctl (GUI side-effect isolation — never call real launchctl)
  mkdir -p "$HOME/.claude/stubs"
  cat > "$HOME/.claude/stubs/launchctl" <<'STUBEOF'
#!/bin/bash
# Stub launchctl — silently succeeds, no-op
exit 0
STUBEOF
  chmod +x "$HOME/.claude/stubs/launchctl"

  # Stub pgrep (used by cast-otel.sh status)
  cat > "$HOME/.claude/stubs/pgrep" <<'STUBEOF'
#!/bin/bash
# Stub pgrep — never finds the process
exit 1
STUBEOF
  chmod +x "$HOME/.claude/stubs/pgrep"

  # Override PATH to use stubs first
  export PATH="$HOME/.claude/stubs:$PATH"

  # Override env vars to use temp settings and disable launchctl
  export CAST_SETTINGS_JSON="$SETTINGS_FILE"
  export CAST_OTEL_LAUNCHCTL_CMD="$HOME/.claude/stubs/launchctl"
  export CAST_OTEL_DRY_RUN="1"  # Prevent any real launchctl calls
}

teardown() {
  teardown_temp_home
  unset SETTINGS_FILE CAST_SETTINGS_JSON CAST_OTEL_LAUNCHCTL_CMD CAST_OTEL_DRY_RUN
}

# ---------------------------------------------------------------------------
# Helper: Count occurrences of a key in the env block of settings.json
# ---------------------------------------------------------------------------
_key_count() {
  local key="$1"
  python3 << PYEOF
import json
import sys

try:
    with open("$SETTINGS_FILE", "r") as f:
        data = json.load(f)
    env = data.get("env", {})
    count = 1 if "$key" in env else 0
    print(count, end='')
except Exception as e:
    print("0", end='')
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: Check if a key exists in settings.json env block
# ---------------------------------------------------------------------------
_key_exists() {
  local key="$1"
  local count
  count=$(_key_count "$key")
  count=$(echo "$count" | tr -d ' ')
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Helper: Get all keys in settings.json env block
# ---------------------------------------------------------------------------
_get_env_keys() {
  python3 << PYEOF
import json
import sys

try:
    with open("$SETTINGS_FILE", "r") as f:
        data = json.load(f)
    env = data.get("env", {})
    for key in sorted(env.keys()):
        print(key)
except Exception as e:
    pass
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: Check if settings.json is valid JSON
# ---------------------------------------------------------------------------
_json_valid() {
  python3 -m json.tool "$SETTINGS_FILE" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: Enable adds 5 telemetry keys to settings.json
# ---------------------------------------------------------------------------
@test "enable command adds 5 telemetry env keys to settings.json" {
  run bash "$OTEL_SH" enable
  assert_success
  assert_output --partial "Enabling CAST OpenTelemetry"

  # All 5 keys must be present
  _key_exists "CLAUDE_CODE_ENABLE_TELEMETRY"
  _key_exists "OTEL_METRICS_EXPORTER"
  _key_exists "OTEL_LOGS_EXPORTER"
  _key_exists "OTEL_EXPORTER_OTLP_PROTOCOL"
  _key_exists "OTEL_EXPORTER_OTLP_ENDPOINT"
}

@test "enable command preserves pre-existing env keys" {
  # Add a pre-existing key
  python3 << PYEOF
import json

with open("$SETTINGS_FILE", "r") as f:
    data = json.load(f)

if "env" not in data:
    data["env"] = {}

data["env"]["MY_CUSTOM_KEY"] = "my_value"

with open("$SETTINGS_FILE", "w") as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF

  # Run enable
  bash "$OTEL_SH" enable >/dev/null 2>&1

  # Pre-existing key must still be there
  python3 << PYEOF
import json

with open("$SETTINGS_FILE", "r") as f:
    data = json.load(f)

env = data.get("env", {})
assert "MY_CUSTOM_KEY" in env
assert env["MY_CUSTOM_KEY"] == "my_value"
PYEOF
}

@test "enable produces valid JSON in settings.json" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  _json_valid
}

# ---------------------------------------------------------------------------
# Test 2: Disable removes exactly 5 telemetry keys
# ---------------------------------------------------------------------------
@test "disable command removes all 5 telemetry env keys from settings.json" {
  # First enable
  bash "$OTEL_SH" enable >/dev/null 2>&1

  # Then disable
  run bash "$OTEL_SH" disable
  assert_success
  assert_output --partial "Disabling CAST OpenTelemetry"

  # All 5 keys must be gone
  ! _key_exists "CLAUDE_CODE_ENABLE_TELEMETRY"
  ! _key_exists "OTEL_METRICS_EXPORTER"
  ! _key_exists "OTEL_LOGS_EXPORTER"
  ! _key_exists "OTEL_EXPORTER_OTLP_PROTOCOL"
  ! _key_exists "OTEL_EXPORTER_OTLP_ENDPOINT"
}

@test "disable preserves pre-existing env keys" {
  # Add a pre-existing key
  python3 << PYEOF
import json

with open("$SETTINGS_FILE", "r") as f:
    data = json.load(f)

if "env" not in data:
    data["env"] = {}

data["env"]["KEEP_THIS_KEY"] = "keep_this_value"

with open("$SETTINGS_FILE", "w") as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF

  # Enable telemetry
  bash "$OTEL_SH" enable >/dev/null 2>&1

  # Disable telemetry
  bash "$OTEL_SH" disable >/dev/null 2>&1

  # Pre-existing key must still be there
  python3 << PYEOF
import json

with open("$SETTINGS_FILE", "r") as f:
    data = json.load(f)

env = data.get("env", {})
assert "KEEP_THIS_KEY" in env
assert env["KEEP_THIS_KEY"] == "keep_this_value"
PYEOF
}

@test "disable produces valid JSON in settings.json" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  bash "$OTEL_SH" disable >/dev/null 2>&1
  _json_valid
}

# ---------------------------------------------------------------------------
# Test 3: Re-enable is idempotent (no duplicate keys)
# ---------------------------------------------------------------------------
@test "re-enable after disable produces no duplicate keys" {
  # Enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local first_enable_count
  first_enable_count=$(python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    data = json.load(f)
print(len(data.get('env', {})))
")

  # Disable
  bash "$OTEL_SH" disable >/dev/null 2>&1

  # Re-enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local second_enable_count
  second_enable_count=$(python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    data = json.load(f)
print(len(data.get('env', {})))
")

  # Counts must be exactly the same (5 telemetry keys, no duplicates)
  [[ "$first_enable_count" -eq "$second_enable_count" ]]
  [[ "$first_enable_count" -eq 5 ]]
}

@test "enable twice produces no duplicate keys" {
  # First enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local first_count
  first_count=$(python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    data = json.load(f)
print(len(data.get('env', {})))
")

  # Second enable (should be idempotent)
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local second_count
  second_count=$(python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    data = json.load(f)
print(len(data.get('env', {})))
")

  # Counts must be exactly the same (no duplicates)
  [[ "$first_count" -eq "$second_count" ]]
  [[ "$first_count" -eq 5 ]]
}

# ---------------------------------------------------------------------------
# Test 4: Status command shows correct information
# ---------------------------------------------------------------------------
@test "status command runs without error" {
  run bash "$OTEL_SH" status
  assert_success
}

@test "status shows 'Not loaded' when disabled" {
  bash "$OTEL_SH" disable >/dev/null 2>&1
  run bash "$OTEL_SH" status
  assert_success
  # Note: our stub launchctl always fails, so status shows "Not loaded"
}

@test "status shows env key count when enabled" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  run bash "$OTEL_SH" status
  assert_success
  assert_output --partial "telemetry keys"
}

# ---------------------------------------------------------------------------
# Test 5: Round-trip enable → disable → enable
# ---------------------------------------------------------------------------
@test "full round-trip: enable → disable → enable produces consistent state" {
  # Initial state: empty
  python3 << PYEOF
import json
with open("$SETTINGS_FILE", "r") as f:
    data = json.load(f)
assert data.get("env", {}) == {}
PYEOF

  # Enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local enabled_state
  enabled_state=$(python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    data = json.load(f)
print(json.dumps(data.get('env', {}), sort_keys=True))
")

  # Disable
  bash "$OTEL_SH" disable >/dev/null 2>&1
  python3 << PYEOF
import json
with open("$SETTINGS_FILE", "r") as f:
    data = json.load(f)
assert data.get("env", {}) == {}
PYEOF

  # Re-enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local reenabled_state
  reenabled_state=$(python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    data = json.load(f)
print(json.dumps(data.get('env', {}), sort_keys=True))
")

  # States must match (idempotent)
  [[ "$enabled_state" == "$reenabled_state" ]]
}

# ---------------------------------------------------------------------------
# Test 6: Unknown subcommand shows usage
# ---------------------------------------------------------------------------
@test "unknown subcommand shows usage and returns error" {
  run bash "$OTEL_SH" unknown-cmd
  assert_failure
  assert_output --partial "Usage:"
  assert_output --partial "enable"
  assert_output --partial "disable"
}

# ---------------------------------------------------------------------------
# Test 7: No arguments shows usage
# ---------------------------------------------------------------------------
@test "no arguments shows usage and returns error" {
  run bash "$OTEL_SH"
  assert_failure
  assert_output --partial "Usage:"
}
