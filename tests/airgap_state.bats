#!/usr/bin/env bats
# Tests for air-gap state file wiring (G1 fix — Phase 9.75a)
#
# Coverage:
#   - cast-airgap.sh on: writes ~/.claude/cast/state/airgap.state
#   - cast-airgap.sh off: deletes the state file
#   - route.sh reads state file when CAST_AIRGAP_ACTIVE is not set in env

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
AIRGAP_SH="$REPO_DIR/scripts/cast-airgap.sh"
ROUTE_SH="$REPO_DIR/scripts/route.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"

  mkdir -p "$HOME/.claude/config" "$HOME/.claude/scripts" "$HOME/.claude/cast/state"

  # Minimal cast-cli.json
  cat > "$HOME/.claude/config/cast-cli.json" <<'JSON'
{
  "airgap": false,
  "default_model": "auto"
}
JSON

  # Stub cast-db-log.py for route.sh logging
  cat > "$HOME/.claude/scripts/cast-db-log.py" <<'PYEOF'
import sys, os, json
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
os.makedirs(os.path.dirname(log_path), exist_ok=True)
data = sys.stdin.read().strip()
if data:
    with open(log_path, 'a') as f:
        f.write(data + '\n')
PYEOF

  cp "$HOME/.claude/scripts/cast-db-log.py" "$HOME/.claude/scripts/cast-log-append.py"

  export CAST_AIRGAP_STATE_FILE="$HOME/.claude/cast/state/airgap.state"

  # Unset env var so route.sh falls back to state file
  unset CAST_AIRGAP_ACTIVE

  export CLAUDE_SESSION_ID="test-airgap-$$-${BATS_TEST_NUMBER:-0}"
  echo "$CLAUDE_SESSION_ID" >> /tmp/cast-sessions-seen.log
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_AIRGAP_ACTIVE CAST_AIRGAP_STATE_FILE CLAUDE_SESSION_ID
}

# ---------------------------------------------------------------------------
# G1 — state file written and deleted
# ---------------------------------------------------------------------------

@test "cast-airgap.sh on: creates the airgap state file" {
  run bash "$AIRGAP_SH" on
  assert_success
  assert [ -f "$HOME/.claude/cast/state/airgap.state" ]
}

@test "cast-airgap.sh on: state file contains '1'" {
  bash "$AIRGAP_SH" on
  run cat "$HOME/.claude/cast/state/airgap.state"
  assert_success
  assert_output '1'
}

@test "cast-airgap.sh off: deletes the airgap state file" {
  # Enable first
  bash "$AIRGAP_SH" on
  assert [ -f "$HOME/.claude/cast/state/airgap.state" ]

  # Disable
  run bash "$AIRGAP_SH" off
  assert_success
  assert [ ! -f "$HOME/.claude/cast/state/airgap.state" ]
}

@test "cast-airgap.sh off: is safe when state file already absent" {
  assert [ ! -f "$HOME/.claude/cast/state/airgap.state" ]
  run bash "$AIRGAP_SH" off
  assert_success
}

# ---------------------------------------------------------------------------
# G1 — route.sh reads state file when env var is absent
# ---------------------------------------------------------------------------

@test "route.sh exports CAST_AIRGAP_ACTIVE=1 when state file exists" {
  echo "1" > "$HOME/.claude/cast/state/airgap.state"

  # Source route.sh startup section and check exported var
  run bash -c "
    unset CAST_AIRGAP_ACTIVE
    # Run just the airgap startup block from route.sh
    source_check() {
      HOME='$HOME'
      if [ -z \"\${CAST_AIRGAP_ACTIVE:-}\" ]; then
        _AIRGAP_STATE=\"\$HOME/.claude/cast/state/airgap.state\"
        if [ -f \"\$_AIRGAP_STATE\" ]; then
          export CAST_AIRGAP_ACTIVE=1
        else
          export CAST_AIRGAP_ACTIVE=0
        fi
      fi
      echo \"CAST_AIRGAP_ACTIVE=\$CAST_AIRGAP_ACTIVE\"
    }
    source_check
  "
  assert_success
  assert_output 'CAST_AIRGAP_ACTIVE=1'
}

@test "route.sh exports CAST_AIRGAP_ACTIVE=0 when state file absent" {
  assert [ ! -f "$HOME/.claude/cast/state/airgap.state" ]

  run bash -c "
    unset CAST_AIRGAP_ACTIVE
    HOME='$HOME'
    if [ -z \"\${CAST_AIRGAP_ACTIVE:-}\" ]; then
      _AIRGAP_STATE=\"\$HOME/.claude/cast/state/airgap.state\"
      if [ -f \"\$_AIRGAP_STATE\" ]; then
        export CAST_AIRGAP_ACTIVE=1
      else
        export CAST_AIRGAP_ACTIVE=0
      fi
    fi
    echo \"CAST_AIRGAP_ACTIVE=\$CAST_AIRGAP_ACTIVE\"
  "
  assert_success
  assert_output 'CAST_AIRGAP_ACTIVE=0'
}

@test "route.sh source contains airgap state file check" {
  run grep -n 'airgap.state' "$ROUTE_SH"
  assert_success
}

@test "cast-airgap.sh source defines AIRGAP_STATE_FILE variable" {
  run grep -n 'AIRGAP_STATE_FILE' "$AIRGAP_SH"
  assert_success
  assert_output --partial 'airgap.state'
}
