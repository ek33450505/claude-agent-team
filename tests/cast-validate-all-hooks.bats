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

# ---------------------------------------------------------------------------
# Test 6: a `python3 <script>.py` hook is actually EXECUTED, not skipped
# ---------------------------------------------------------------------------

# Emits a marker in the [ok]/[warn]/[fail] line so we can prove it ran
# rather than being warned-away by the old `${cmd#bash }` decomposition.
_write_python_marker_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
import json, sys
if __import__("os").environ.get("CLAUDE_SUBPROCESS", "0") == "1":
    sys.exit(0)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "PY_MARKER_EXECUTED"
    }
}))
SCRIPT
  chmod +x "$path"
}

@test "validate-all: a python3-invoked hook is executed, not skipped as script-not-found" {
  local py_hook="$TEST_TMPDIR/marker-hook.py"
  local settings="$TEST_TMPDIR/settings.json"

  _write_python_marker_hook "$py_hook"

  export _SETTINGS_PATH="$settings"
  export _PY_HOOK="$py_hook"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
py_hook = os.environ["_PY_HOOK"]
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-python-hook",
                "hooks": [{"type": "command", "command": f"python3 {py_hook}", "timeout": 3}]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

  local fake_home="$TEST_TMPDIR/fh_pymarker"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_success
  # Executed (not skipped) and its shape was validated ok.
  [[ "$output" =~ "1 executed" ]]
  [[ "$output" =~ "0 skipped" ]]
  refute_output --partial "script not found"
}

# ---------------------------------------------------------------------------
# Test 7: a hook with an argument receives it
# ---------------------------------------------------------------------------

_write_arg_sensitive_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
mode="${1:-missing}"
if [[ "$mode" == "post" ]]; then
  python3 - <<'PYEOF'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "mode=post"
    }
}))
PYEOF
else
  # No arg reached us — emit a shape the validator will FAIL on, proving
  # the arg was (or wasn't) delivered.
  echo "not json"
fi
SCRIPT
  chmod +x "$path"
}

@test "validate-all: a hook command's argument is passed through to the hook" {
  local arg_hook="$TEST_TMPDIR/arg-hook.sh"
  local settings="$TEST_TMPDIR/settings.json"

  _write_arg_sensitive_hook "$arg_hook"

  export _SETTINGS_PATH="$settings"
  export _ARG_HOOK="$arg_hook"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
arg_hook = os.environ["_ARG_HOOK"]
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-arg-hook",
                "hooks": [{"type": "command", "command": f"bash {arg_hook} post", "timeout": 3}]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

  local fake_home="$TEST_TMPDIR/fh_arg"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_success
  [[ "$output" =~ "1 ok" ]]
}

# ---------------------------------------------------------------------------
# Test 8: an unresolvable/unrunnable hook makes the validator exit non-zero
# (regression guard for the whole "warn instead of fail" defect class)
# ---------------------------------------------------------------------------

@test "validate-all: an unrunnable hook FAILS the gate (exits non-zero), not just warns" {
  local settings="$TEST_TMPDIR/settings.json"

  export _SETTINGS_PATH="$settings"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-unrunnable-hook",
                "hooks": [{"type": "command", "command": "bash /nonexistent/does-not-exist.sh", "timeout": 3}]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

  local fake_home="$TEST_TMPDIR/fh_unrunnable"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_failure
  [[ "$output" =~ "1 fail" ]]
  refute_output --partial "1 warn"
}

# ---------------------------------------------------------------------------
# Test 9: a hook entry carrying an `args` key (exec form) is reported as fail
# ---------------------------------------------------------------------------

@test "validate-all: a hook with an 'args' key (exec form) is reported as fail" {
  local settings="$TEST_TMPDIR/settings.json"

  export _SETTINGS_PATH="$settings"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-execform-hook",
                "hooks": [{"type": "command", "command": "some-tool", "args": ["--flag"], "timeout": 3}]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

  local fake_home="$TEST_TMPDIR/fh_execform"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_failure
  [[ "$output" =~ "1 fail" ]]
  [[ "$output" =~ "1 skipped" ]]
  [[ "$output" =~ "args" ]]
}

# ---------------------------------------------------------------------------
# Test 10: the real E-1 shape — `python3 <missing .py>` — must FAIL.
# python3 exists on PATH, so `sh -c` happily execs it; python3 itself exits
# 2 ("can't open file"), which is indistinguishable from a legitimate
# PreToolUse block by exit code alone. Only a pre-execution existence
# check (not exit-code inference) can catch this deterministically.
# ---------------------------------------------------------------------------

@test "validate-all: python3 <missing .py> hook FAILS (not silently ok)" {
  local settings="$TEST_TMPDIR/settings.json"

  export _SETTINGS_PATH="$settings"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-missing-python-hook",
                "hooks": [{"type": "command", "command": "python3 ~/.claude/scripts/does-not-exist.py", "timeout": 3}]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

  local fake_home="$TEST_TMPDIR/fh_missingpy"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_failure
  [[ "$output" =~ "1 fail" ]]
  [[ "$output" =~ "0 executed" ]]
  refute_output --partial "1 ok"
}

# ---------------------------------------------------------------------------
# Test 11: guard against overcorrection — a hook that legitimately exits 2
# (simulating a real PreToolUse block, e.g. cast-pretool-dispatch.py
# blocking a destructive command) must NOT be reported as broken.
# ---------------------------------------------------------------------------

_write_blocking_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
echo "**[CAST]** blocked for test" >&2
exit 2
SCRIPT
  chmod +x "$path"
}

@test "validate-all: a hook that legitimately exits 2 (a real block) is NOT reported as broken" {
  local blocking_hook="$TEST_TMPDIR/blocking-hook.sh"
  local settings="$TEST_TMPDIR/settings.json"

  _write_blocking_hook "$blocking_hook"
  _write_synthetic_settings "$settings" "PreToolUse" "$blocking_hook"

  local fake_home="$TEST_TMPDIR/fh_blocking"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR_ALL"
  assert_success
  [[ "$output" =~ "1 ok" ]]
  [[ "$output" =~ "1 executed" ]]
  refute_output --partial "1 fail"
}
