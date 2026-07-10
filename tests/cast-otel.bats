#!/usr/bin/env bats
# cast-otel.bats — BATS tests for cast-otel.sh
#
# Tests the control surface (enable/disable/status) for the CAST OpenTelemetry
# collector daemon, focusing on fragment mutation and env key management.
#
# Telemetry is OFF by default. enable/disable target managed-settings.d/12-otel.json
# (the dedicated telemetry fragment, separate from the shared 00-env.json).
# DISABLE_TELEMETRY is NOT managed by enable/disable — it lives in the personal
# overlay (managed-settings-personal/12-otel.json) for the maintainer only.
#
# All tests use an isolated temp HOME, temp fragment, and stub launchctl/pgrep
# to avoid any real daemon/system interactions.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
OTEL_SH="$REPO_DIR/scripts/cast-otel.sh"

# The 5 telemetry keys that enable/disable manages (DISABLE_TELEMETRY is NOT in this list)
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

  # Fragment path — dedicated telemetry fragment (enable/disable target 12-otel.json)
  mkdir -p "$HOME/.claude/managed-settings.d"
  export FRAGMENT_FILE="$HOME/.claude/managed-settings.d/12-otel.json"

  # Initialize fragment with pre-existing keys (simulates personal overlay on maintainer's machine).
  # DISABLE_TELEMETRY is set here to verify enable/disable never touch it.
  # A_SEPARATE_KEY simulates any non-telemetry key that might coexist in the fragment.
  python3 << PYEOF
import json
data = {"env": {"DISABLE_TELEMETRY": "1", "A_SEPARATE_KEY": "preserved"}}
with open("$FRAGMENT_FILE", "w") as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF

  # Temp settings.json (generated from fragment — not the source of truth)
  export SETTINGS_FILE="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$SETTINGS_FILE")"
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

  # Override env vars to use temp paths and disable launchctl
  export CAST_SETTINGS_JSON="$SETTINGS_FILE"
  export CAST_OTEL_FRAGMENT="$FRAGMENT_FILE"
  export CAST_CLAUDE_DIR="$HOME/.claude"
  export CAST_OTEL_LAUNCHCTL_CMD="$HOME/.claude/stubs/launchctl"
  export CAST_OTEL_DRY_RUN="1"  # Prevent any real launchctl calls
}

teardown() {
  teardown_temp_home
  unset FRAGMENT_FILE SETTINGS_FILE CAST_SETTINGS_JSON CAST_OTEL_FRAGMENT \
        CAST_CLAUDE_DIR CAST_OTEL_LAUNCHCTL_CMD CAST_OTEL_DRY_RUN
}

# ---------------------------------------------------------------------------
# Helper: Count occurrences of a key in the env block of the FRAGMENT
# ---------------------------------------------------------------------------
_key_count_in_fragment() {
  local key="$1"
  python3 << PYEOF
import json
import sys

try:
    with open("$FRAGMENT_FILE", "r") as f:
        data = json.load(f)
    env = data.get("env", {})
    count = 1 if "$key" in env else 0
    print(count, end='')
except Exception as e:
    print("0", end='')
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: Check if a key exists in the fragment env block
# ---------------------------------------------------------------------------
_key_exists() {
  local key="$1"
  local count
  count=$(_key_count_in_fragment "$key")
  count=$(echo "$count" | tr -d ' ')
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Helper: Get all keys in the fragment env block
# ---------------------------------------------------------------------------
_get_fragment_env_keys() {
  python3 << PYEOF
import json
import sys

try:
    with open("$FRAGMENT_FILE", "r") as f:
        data = json.load(f)
    env = data.get("env", {})
    for key in sorted(env.keys()):
        print(key)
except Exception as e:
    pass
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: Check if fragment is valid JSON
# ---------------------------------------------------------------------------
_fragment_json_valid() {
  python3 -m json.tool "$FRAGMENT_FILE" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: Enable adds 5 telemetry keys to the FRAGMENT
# ---------------------------------------------------------------------------
@test "enable command adds 5 telemetry env keys to the fragment" {
  run bash "$OTEL_SH" enable
  assert_success
  assert_output --partial "Enabling CAST OpenTelemetry"

  # All 5 keys must be present in the fragment
  _key_exists "CLAUDE_CODE_ENABLE_TELEMETRY"
  _key_exists "OTEL_METRICS_EXPORTER"
  _key_exists "OTEL_LOGS_EXPORTER"
  _key_exists "OTEL_EXPORTER_OTLP_PROTOCOL"
  _key_exists "OTEL_EXPORTER_OTLP_ENDPOINT"
}

@test "enable command preserves pre-existing env keys in fragment" {
  # Pre-existing keys (DISABLE_TELEMETRY + A_SEPARATE_KEY) already in fragment from setup

  # Run enable
  bash "$OTEL_SH" enable >/dev/null 2>&1

  # Pre-existing keys must still be there
  python3 << PYEOF
import json

with open("$FRAGMENT_FILE", "r") as f:
    data = json.load(f)

env = data.get("env", {})
assert "DISABLE_TELEMETRY" in env, "DISABLE_TELEMETRY missing after enable"
assert env["DISABLE_TELEMETRY"] == "1", f"DISABLE_TELEMETRY wrong value: {env['DISABLE_TELEMETRY']}"
assert "A_SEPARATE_KEY" in env, "A_SEPARATE_KEY missing after enable"
PYEOF
}

@test "enable produces valid JSON in fragment" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  _fragment_json_valid
}

# ---------------------------------------------------------------------------
# Test 2: Disable removes exactly 5 telemetry keys from the FRAGMENT
# ---------------------------------------------------------------------------
@test "disable command removes all 5 telemetry env keys from the fragment" {
  # First enable
  bash "$OTEL_SH" enable >/dev/null 2>&1

  # Then disable
  run bash "$OTEL_SH" disable
  assert_success
  assert_output --partial "Disabling CAST OpenTelemetry"

  # All 5 OTEL keys must be gone from fragment
  ! _key_exists "CLAUDE_CODE_ENABLE_TELEMETRY"
  ! _key_exists "OTEL_METRICS_EXPORTER"
  ! _key_exists "OTEL_LOGS_EXPORTER"
  ! _key_exists "OTEL_EXPORTER_OTLP_PROTOCOL"
  ! _key_exists "OTEL_EXPORTER_OTLP_ENDPOINT"
}

@test "disable preserves DISABLE_TELEMETRY and other fragment keys" {
  # Enable telemetry
  bash "$OTEL_SH" enable >/dev/null 2>&1

  # Disable telemetry
  bash "$OTEL_SH" disable >/dev/null 2>&1

  # DISABLE_TELEMETRY must still be in the fragment (it is NOT managed by enable/disable)
  python3 << PYEOF
import json

with open("$FRAGMENT_FILE", "r") as f:
    data = json.load(f)

env = data.get("env", {})
assert "DISABLE_TELEMETRY" in env, "DISABLE_TELEMETRY was removed by disable — it should be preserved"
assert "A_SEPARATE_KEY" in env, "A_SEPARATE_KEY was removed by disable — it should be preserved"
PYEOF
}

@test "disable produces valid JSON in fragment" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  bash "$OTEL_SH" disable >/dev/null 2>&1
  _fragment_json_valid
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
with open('$FRAGMENT_FILE', 'r') as f:
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
with open('$FRAGMENT_FILE', 'r') as f:
    data = json.load(f)
print(len(data.get('env', {})))
")

  # Counts must be exactly the same (5 telemetry keys + 2 pre-existing = 7, no duplicates)
  [[ "$first_enable_count" -eq "$second_enable_count" ]]
  # 5 OTEL keys + DISABLE_TELEMETRY + A_SEPARATE_KEY = 7
  [[ "$first_enable_count" -eq 7 ]]
}

@test "enable twice produces no duplicate keys" {
  # First enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local first_count
  first_count=$(python3 -c "
import json
with open('$FRAGMENT_FILE', 'r') as f:
    data = json.load(f)
print(len(data.get('env', {})))
")

  # Second enable (should be idempotent)
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local second_count
  second_count=$(python3 -c "
import json
with open('$FRAGMENT_FILE', 'r') as f:
    data = json.load(f)
print(len(data.get('env', {})))
")

  # Counts must be exactly the same (no duplicates)
  [[ "$first_count" -eq "$second_count" ]]
  # 5 OTEL keys + DISABLE_TELEMETRY + A_SEPARATE_KEY = 7
  [[ "$first_count" -eq 7 ]]
}

# ---------------------------------------------------------------------------
# Test 4: Status command shows correct information
# ---------------------------------------------------------------------------
@test "status command runs without error" {
  run bash "$OTEL_SH" status
  assert_success
}

@test "status shows 'Not loaded' when daemon is not loaded" {
  # Stub launchctl exits 1 for 'list' (daemon not loaded)
  cat > "$HOME/.claude/stubs/launchctl" <<'STUBEOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
  exit 1
fi
exit 0
STUBEOF
  # Override to use real launchctl for status path but non-DRY_RUN
  CAST_OTEL_DRY_RUN="0" run bash "$OTEL_SH" status
  assert_success
  assert_output --partial "Not loaded"
}

@test "status shows env key count after enable" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  run bash "$OTEL_SH" status
  assert_success
  assert_output --partial "telemetry keys"
}

@test "status reflects fragment when fragment is present" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  run bash "$OTEL_SH" status
  assert_success
  assert_output --partial "fragment"
}

# ---------------------------------------------------------------------------
# Test 5: Round-trip enable → disable → enable
# ---------------------------------------------------------------------------
@test "full round-trip: enable → disable → enable produces consistent state" {
  # Initial state: only pre-existing keys (DISABLE_TELEMETRY + A_SEPARATE_KEY); no OTEL feed keys
  python3 << PYEOF
import json
with open("$FRAGMENT_FILE", "r") as f:
    data = json.load(f)
env = data.get("env", {})
assert "CLAUDE_CODE_ENABLE_TELEMETRY" not in env
PYEOF

  # Enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local enabled_state
  enabled_state=$(python3 -c "
import json
with open('$FRAGMENT_FILE', 'r') as f:
    data = json.load(f)
print(json.dumps(data.get('env', {}), sort_keys=True))
")

  # Disable
  bash "$OTEL_SH" disable >/dev/null 2>&1
  python3 << PYEOF
import json
with open("$FRAGMENT_FILE", "r") as f:
    data = json.load(f)
env = data.get("env", {})
assert "CLAUDE_CODE_ENABLE_TELEMETRY" not in env
PYEOF

  # Re-enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  local reenabled_state
  reenabled_state=$(python3 -c "
import json
with open('$FRAGMENT_FILE', 'r') as f:
    data = json.load(f)
print(json.dumps(data.get('env', {}), sort_keys=True))
")

  # States must match (idempotent)
  [[ "$enabled_state" == "$reenabled_state" ]]
}

# ---------------------------------------------------------------------------
# Test 5b: DRY_RUN mode emits PlistBuddy intent messages
# ---------------------------------------------------------------------------
@test "enable in DRY_RUN emits 'would set RunAtLoad true' message" {
  # DRY_RUN=1 is set in setup; PlistBuddy must NOT run (it's in non-DRY_RUN block)
  run bash "$OTEL_SH" enable
  assert_success
  assert_output --partial "would set RunAtLoad true"
  assert_output --partial "would load:"
}

@test "disable in DRY_RUN emits 'would set RunAtLoad false' message" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  run bash "$OTEL_SH" disable
  assert_success
  assert_output --partial "would unload:"
  assert_output --partial "would set RunAtLoad false"
}

@test "enable sets fragment permissions to 600" {
  bash "$OTEL_SH" enable >/dev/null 2>&1
  # chmod 600 runs unconditionally (fragment always exists after enable)
  local perms
  perms="$(stat -c '%a' "$FRAGMENT_FILE" 2>/dev/null || stat -f '%OLp' "$FRAGMENT_FILE" 2>/dev/null)"
  [[ "$perms" == "600" ]] || {
    echo "FAIL: fragment permissions are $perms (expected 600)" >&2
    return 1
  }
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

# ---------------------------------------------------------------------------
# Test 8: DISABLE_TELEMETRY survives full enable/disable cycle
# ---------------------------------------------------------------------------
@test "DISABLE_TELEMETRY is never removed by enable or disable" {
  # Enable
  bash "$OTEL_SH" enable >/dev/null 2>&1
  _key_exists "DISABLE_TELEMETRY"

  # Disable
  bash "$OTEL_SH" disable >/dev/null 2>&1
  _key_exists "DISABLE_TELEMETRY"
}

# ---------------------------------------------------------------------------
# Test 9: Repo source 00-env.json contains NONE of the 6 telemetry keys
# ---------------------------------------------------------------------------
@test "repo 00-env.json contains none of the 6 telemetry keys" {
  local repo_fragment="$REPO_DIR/managed-settings.d/00-env.json"
  [ -f "$repo_fragment" ] || { echo "FAIL: $repo_fragment not found" >&2; return 1; }

  python3 << PYEOF
import json
import sys

TELEMETRY_KEYS = [
    "CLAUDE_CODE_ENABLE_TELEMETRY",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "DISABLE_TELEMETRY",
]

with open("$repo_fragment", "r") as f:
    data = json.load(f)

env = data.get("env", {})
found = [k for k in TELEMETRY_KEYS if k in env]
if found:
    print(f"FAIL: 00-env.json must not contain telemetry keys, but found: {found}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# Test 10: Repo personal overlay 12-otel.json exists and contains all 5 telemetry keys
# ---------------------------------------------------------------------------
@test "repo managed-settings-personal/12-otel.json exists and contains all 5 telemetry keys" {
  local personal_fragment="$REPO_DIR/managed-settings-personal/12-otel.json"
  [ -f "$personal_fragment" ] || {
    echo "FAIL: $personal_fragment not found — create it with the 5 telemetry keys" >&2
    return 1
  }

  python3 << PYEOF
import json
import sys

TELEMETRY_KEYS = [
    "CLAUDE_CODE_ENABLE_TELEMETRY",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
]

with open("$personal_fragment", "r") as f:
    data = json.load(f)

env = data.get("env", {})
missing = [k for k in TELEMETRY_KEYS if k not in env]
if missing:
    print(f"FAIL: managed-settings-personal/12-otel.json missing telemetry keys: {missing}", file=sys.stderr)
    sys.exit(1)
PYEOF
}
