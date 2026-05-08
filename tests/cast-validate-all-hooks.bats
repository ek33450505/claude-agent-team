#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR_ALL="$REPO_DIR/scripts/cast-validate-all-hooks.sh"
VALIDATOR_CONTRACT="$REPO_DIR/scripts/cast-validate-hook-contracts.sh"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  export TEST_TMPDIR="$(mktemp -d /tmp/cast-validate-all-hooks-test.XXXXXXXX)"
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a hook that emits a valid SessionStart hookSpecificOutput
_write_valid_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
python3 - <<'PYEOF'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "test context"
    }
}))
PYEOF
SCRIPT
  chmod +x "$path"
}

# Write a hook that emits stringified hookSpecificOutput (the bug class)
_write_stringified_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
python3 - <<'PYEOF'
import json
# BUG: hookSpecificOutput is a string, not an object
inner = json.dumps({"hookEventName": "SessionStart", "additionalContext": "test"})
print(json.dumps({"hookSpecificOutput": inner}))
PYEOF
SCRIPT
  chmod +x "$path"
}

# Write a hook that emits wrong hookEventName
_write_wrong_event_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
python3 - <<'PYEOF'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "WrongEvent",
        "additionalContext": "test"
    }
}))
PYEOF
SCRIPT
  chmod +x "$path"
}

# Write a logging-only hook (no stdout)
_write_logging_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
exit 0
SCRIPT
  chmod +x "$path"
}

# Write a synthetic settings.json referencing given hooks
_write_synthetic_settings() {
  local settings_path="$1"
  shift
  # remaining args: event1 hookpath1 event2 hookpath2 ...
  export _SETTINGS_PATH="$settings_path"
  local args_json=""
  while [[ $# -ge 2 ]]; do
    local event="$1"
    local hook_path="$2"
    args_json+="$event $hook_path "
    shift 2
  done
  export _HOOKS_SPEC="$args_json"
  python3 - <<'PYEOF'
import json, os

settings_path = os.environ["_SETTINGS_PATH"]
spec = os.environ.get("_HOOKS_SPEC", "").strip().split()

hooks = {}
i = 0
while i + 1 < len(spec):
    event = spec[i]
    hook_path = spec[i + 1]
    if event not in hooks:
        hooks[event] = []
    hooks[event].append({
        "id": f"test-{event.lower()}-hook",
        "hooks": [
            {"type": "command", "command": f"bash {hook_path}", "timeout": 3}
        ]
    })
    i += 2

data = {"hooks": hooks}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# Run the validate-all script with a synthetic settings.json
_run_validate_all() {
  local settings_path="$1"
  local fake_home="$TEST_TMPDIR/fakehome_${RANDOM}"
  mkdir -p "$fake_home/.claude"
  cp "$settings_path" "$fake_home/.claude/settings.json"
  HOME="$fake_home" bash "$VALIDATOR_ALL" 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: green when all hooks emit valid output
# ---------------------------------------------------------------------------

@test "validate-all: exits 0 when all hooks emit valid output" {
  local valid_hook="$TEST_TMPDIR/valid-hook.sh"
  local settings="$TEST_TMPDIR/settings.json"

  _write_valid_hook "$valid_hook"
  _write_synthetic_settings "$settings" "SessionStart" "$valid_hook"

  local fake_home="$TEST_TMPDIR/fh_valid"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_success
  [[ "$output" =~ "validated" ]]
  [[ "$output" =~ "ok" ]]
}

# ---------------------------------------------------------------------------
# Test 2: red when one hook emits stringified hookSpecificOutput (the bug class)
# ---------------------------------------------------------------------------

@test "validate-all: exits non-zero when hook emits stringified hookSpecificOutput" {
  local bad_hook="$TEST_TMPDIR/stringified-hook.sh"
  local settings="$TEST_TMPDIR/settings.json"

  _write_stringified_hook "$bad_hook"
  _write_synthetic_settings "$settings" "SessionStart" "$bad_hook"

  local fake_home="$TEST_TMPDIR/fh_stringified"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  # Validator writes [fail] messages to stderr; merge stderr so $output sees them.
  run bash -c "env HOME='$fake_home' bash '$VALIDATOR_ALL' 2>&1"
  assert_failure
  [[ "$output" =~ "1 fail" ]]
}

# ---------------------------------------------------------------------------
# Test 3: red when one hook emits wrong hookEventName
# ---------------------------------------------------------------------------

@test "validate-all: exits non-zero when hook emits wrong hookEventName" {
  local bad_hook="$TEST_TMPDIR/wrong-event-hook.sh"
  local settings="$TEST_TMPDIR/settings.json"

  _write_wrong_event_hook "$bad_hook"
  _write_synthetic_settings "$settings" "SessionStart" "$bad_hook"

  local fake_home="$TEST_TMPDIR/fh_wrongevent"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  # Validator writes [fail] messages to stderr; merge stderr so $output sees them.
  run bash -c "env HOME='$fake_home' bash '$VALIDATOR_ALL' 2>&1"
  assert_failure
  [[ "$output" =~ "1 fail" ]]
}

# ---------------------------------------------------------------------------
# Test 4: summary line always printed
# ---------------------------------------------------------------------------

@test "validate-all: always prints summary line" {
  local valid_hook="$TEST_TMPDIR/valid2-hook.sh"
  local settings="$TEST_TMPDIR/settings.json"

  _write_logging_hook "$valid_hook"
  _write_synthetic_settings "$settings" "SessionStart" "$valid_hook"

  local fake_home="$TEST_TMPDIR/fh_summary"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  local combined
  combined="$(env HOME="$fake_home" bash "$VALIDATOR_ALL" 2>&1 || true)"
  [[ "$combined" =~ "validated" ]]
}

# ---------------------------------------------------------------------------
# Test 5: mixed hooks — ok + fail — exits non-zero
# ---------------------------------------------------------------------------

@test "validate-all: exits non-zero when some hooks fail and some pass" {
  local valid_hook="$TEST_TMPDIR/valid3-hook.sh"
  local bad_hook="$TEST_TMPDIR/bad3-hook.sh"
  local settings="$TEST_TMPDIR/settings.json"

  _write_valid_hook "$valid_hook"
  _write_stringified_hook "$bad_hook"

  # Two SessionStart hooks: valid + bad
  export _SETTINGS_PATH="$settings"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
valid_hook = os.environ["TEST_TMPDIR"] + "/valid3-hook.sh"
bad_hook = os.environ["TEST_TMPDIR"] + "/bad3-hook.sh"
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-valid-hook",
                "hooks": [{"type": "command", "command": f"bash {valid_hook}", "timeout": 3}]
            },
            {
                "id": "test-bad-hook",
                "hooks": [{"type": "command", "command": f"bash {bad_hook}", "timeout": 3}]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

  local fake_home="$TEST_TMPDIR/fh_mixed"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_failure
}
