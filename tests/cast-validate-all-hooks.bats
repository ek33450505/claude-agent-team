#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR_ALL="$REPO_DIR/scripts/cast-validate-all-hooks.sh"
VALIDATOR_CONTRACT="$REPO_DIR/scripts/cast-validate-hook-contracts.sh"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

# Isolation note: this file predates the setup_temp_home/teardown_temp_home
# helpers and does NOT use them. It is still HOME-safe, by a different
# mechanism: every test that can reach $HOME invokes the validator as
# `run env HOME="$TEST_TMPDIR/fh_*" ...`, so the real $HOME is never read,
# and teardown only rm -rf's the /tmp path from mktemp (guarded non-empty).
# Verified empirically 2026-08-26: the real ~/.claude was byte-identical
# before and after a full run of this file.
# Migrating to the canonical helpers is tracked as a follow-up — doing it
# here would rewrite 11 pre-existing tests for no isolation gain.
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

# ---------------------------------------------------------------------------
# J-1: --source must execute the REPO working-tree copy, not the installed
# ~/.claude/scripts/<name> copy, even though settings.json always spells the
# hook command with the installed absolute path. Build a real fake "repo"
# (own scripts/ dir + settings.json) so REPO_DIR resolves to it via the
# script's own BASH_SOURCE location, exactly like the real repo does.
# ---------------------------------------------------------------------------

# Scaffold a fake repo: $dir/settings.json + $dir/scripts/{cast-validate-all-hooks.sh copy,
# cast-validate-hook-contracts.sh placeholder}. cast-validate-hook-contracts.sh is never
# actually invoked by cast-validate-all-hooks.sh (only existence-checked at startup), so a
# placeholder is sufficient.
_setup_fake_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cp "$VALIDATOR_ALL" "$dir/scripts/cast-validate-all-hooks.sh"
  echo '#!/usr/bin/env bash' >"$dir/scripts/cast-validate-hook-contracts.sh"
  # The validator removes its sandbox through cast_safe_rm (blast-radius lint), sourced
  # from its own scripts/ dir — a fake repo without the lib would leak the sandbox.
  cp "$REPO_DIR/scripts/cast-guard-lib.sh" "$dir/scripts/cast-guard-lib.sh"
  chmod +x "$dir/scripts/cast-validate-all-hooks.sh" "$dir/scripts/cast-validate-hook-contracts.sh"
}

# settings.json with one hook whose command uses the literal installed-path form
# (the form every real hook in settings.json actually uses).
_write_source_settings() {
  local settings_path="$1"
  local hook_name="$2"
  export _SETTINGS_PATH="$settings_path"
  export _HOOK_NAME="$hook_name"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
hook_name = os.environ["_HOOK_NAME"]
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-source-rewrite-hook",
                "hooks": [{"type": "command", "command": f"bash ~/.claude/scripts/{hook_name}", "timeout": 3}]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

@test "validate-all --source: rewrites ~/.claude/scripts/<name> to the repo scripts/ copy and executes it" {
  local fakerepo="$TEST_TMPDIR/fakerepo1"
  local fake_home="$TEST_TMPDIR/fh_source1"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude"

  # The hook exists ONLY in the repo copy, never under the fake $HOME's
  # installed location — so success is only possible if the command was
  # actually rewritten to the repo path before execution (a real
  # discriminator, not a string match on output).
  _write_valid_hook "$fakerepo/scripts/source-rewrite-marker.sh"
  _write_source_settings "$fakerepo/settings.json" "source-rewrite-marker.sh"

  run env HOME="$fake_home" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success
  [[ "$output" =~ "1 ok" ]]
  [[ "$output" =~ "1 executed" ]]
  [[ "$output" =~ "0 skipped" ]]
}

@test "validate-all --source: a rewritten path missing from the repo FAILS distinctly, not a silent skip" {
  local fakerepo="$TEST_TMPDIR/fakerepo2"
  local fake_home="$TEST_TMPDIR/fh_source2"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude"

  # Deliberately do NOT create does-not-exist-in-repo.sh anywhere.
  _write_source_settings "$fakerepo/settings.json" "does-not-exist-in-repo.sh"

  run env HOME="$fake_home" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_failure
  [[ "$output" =~ "1 fail" ]]
  [[ "$output" =~ "1 skipped" ]]
  [[ "$output" =~ "0 executed" ]]
  # The [fail] message must show the REWRITTEN (repo) path was checked, proving
  # the rewrite ran rather than silently falling through to the installed path.
  assert_output --partial "$fakerepo/scripts/does-not-exist-in-repo.sh"
  refute_output --partial "$fake_home/.claude/scripts/does-not-exist-in-repo.sh"
}

@test "validate-all --runtime: does NOT rewrite ~/.claude paths (rewrite is --source only)" {
  local fakerepo="$TEST_TMPDIR/fakerepo3"
  local fake_home="$TEST_TMPDIR/fh_source3"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude"

  # Same hook that succeeds under --source (repo-only copy) must FAIL under
  # --runtime, because --runtime reads $HOME/.claude/settings.json and must
  # resolve against $HOME/.claude/scripts/, never the repo.
  _write_valid_hook "$fakerepo/scripts/source-rewrite-marker.sh"
  _write_source_settings "$fake_home/.claude/settings.json" "source-rewrite-marker.sh"

  run env HOME="$fake_home" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --runtime
  assert_failure
  [[ "$output" =~ "1 fail" ]]
  assert_output --partial "$fake_home/.claude/scripts/source-rewrite-marker.sh"
}

# ---------------------------------------------------------------------------
# Top-level `decision` is validated for EVERY event (2026-10-05). Claude Code accepts only
# "approve" | "block" and rejects anything else at runtime ("decision: Invalid option: expected
# one of approve|block"). This is the validator the CI hook-contract-validation job runs
# (`--source`); its embedded checker had no decision check, so {"decision":"allow"} passed.
# Fixtures are planted the way the tests above plant theirs: a synthetic settings.json in a
# per-test fake HOME, validator run with `env HOME=<fake>` (the real HOME is never read).
# ---------------------------------------------------------------------------

# Write a hook that prints the given JSON line on stdout
_write_json_hook() { # path json
  local path="$1" json="$2"
  cat > "$path" <<SCRIPT
#!/usr/bin/env bash
if [[ "\${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
cat <<'JSONEOF'
$json
JSONEOF
SCRIPT
  chmod +x "$path"
}

# Plant a hook printing $2 under event $1 in a fake HOME and run the validator (sets $status/$output)
_validate_all_event_fixture() { # event json
  local event="$1" json="$2"
  local hook="$TEST_TMPDIR/decision-$event-hook.sh"
  local settings="$TEST_TMPDIR/decision-$event-settings.json"
  local fake_home="$TEST_TMPDIR/fh_decision_$event"
  _write_json_hook "$hook" "$json"
  _write_synthetic_settings "$settings" "$event" "$hook"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"
  # [fail] messages go to stderr; merge so $output sees them.
  run bash -c "env HOME='$fake_home' bash '$VALIDATOR_ALL' 2>&1"
}

@test "validate-all: FAILS a PreCompact hook that prints decision=allow (Claude Code accepts only approve|block)" {
  _validate_all_event_fixture PreCompact '{"decision":"allow"}'
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] test-precompact-hook (PreCompact)"
  assert_output --partial "invalid top-level decision value 'allow' (Claude Code accepts only approve|block)"
  # the failing hook must not ALSO be reported as a shape-valid ok
  refute_output --partial "[ok] test-precompact-hook"
  [[ "$output" =~ "1 fail" ]]
}

@test "validate-all: FAILS a Stop hook that prints decision=continue" {
  _validate_all_event_fixture Stop '{"decision":"continue"}'
  [ "$status" -eq 2 ]
  assert_output --partial "invalid top-level decision value 'continue'"
}

@test "validate-all: accepts decision=block on PreCompact (control: no invalid-decision failure)" {
  _validate_all_event_fixture PreCompact '{"decision":"block","reason":"x"}'
  [ "$status" -eq 0 ]
  assert_output --partial "[ok] test-precompact-hook (PreCompact)"
  refute_output --partial "invalid top-level decision"
  [[ "$output" =~ "0 fail" ]]
}

@test "validate-all: accepts decision=approve on Stop (control: no invalid-decision failure)" {
  _validate_all_event_fixture Stop '{"decision":"approve"}'
  [ "$status" -eq 0 ]
  refute_output --partial "invalid top-level decision"
}

@test "validate-all: accepts empty stdout on PreCompact (the proceed contract)" {
  local hook="$TEST_TMPDIR/decision-silent-hook.sh" settings="$TEST_TMPDIR/decision-silent-settings.json"
  local fake_home="$TEST_TMPDIR/fh_decision_silent"
  _write_logging_hook "$hook"
  _write_synthetic_settings "$settings" PreCompact "$hook"
  mkdir -p "$fake_home/.claude"
  cp "$settings" "$fake_home/.claude/settings.json"
  run bash -c "env HOME='$fake_home' bash '$VALIDATOR_ALL' 2>&1"
  [ "$status" -eq 0 ]
  assert_output --partial "empty stdout"
}

# Fail if ANY output line starts with a forged "[ok] forged" marker (a hook-controlled string that
# reached the log unescaped can inject a line break and forge a validator verdict line).
_refute_forged_ok_line() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "[ok] forged"*)
        echo "forged line leaked: $line" >&2
        return 1
        ;;
    esac
  done <<< "$output"
}

@test "validate-all: escapes a hook-controlled decision value (no forged [ok] line in the log)" {
  _validate_all_event_fixture PreCompact '{"decision":"allow\n[ok] forged"}'
  [ "$status" -eq 2 ]
  # the newline is escaped (repr), so the value stays on ONE line...
  assert_output --partial '\n[ok] forged'
  # ...and no output line may start with a forged [ok] marker
  _refute_forged_ok_line
}

@test "validate-all: escapes a hook-controlled unknown KEY (no forged [ok] line in the log)" {
  _validate_all_event_fixture PreCompact '{"zz\n[ok] forged-via-key":1}'
  # the key is reported (unknown key warn) with its newline escaped, on ONE line...
  assert_output --partial 'unknown key'
  assert_output --partial '\n[ok] forged-via-key'
  _refute_forged_ok_line
}

@test "validate-all: escapes a hook-controlled hookEventName (no forged [ok] line in the log)" {
  _validate_all_event_fixture SessionStart '{"hookSpecificOutput":{"hookEventName":"x\n[ok] forged-via-event","additionalContext":""}}'
  [ "$status" -eq 2 ]
  assert_output --partial "wrong hookEventName"
  assert_output --partial '\n[ok] forged-via-event'
  _refute_forged_ok_line
}

# ---------------------------------------------------------------------------
# V2 (2026-10-05): hooks must receive VALID JSON on stdin — the old
# `${!payload_var:-{}}` ended at the first '}' and appended a stray one, so every
# hook was validated on INVALID JSON — and, now that real hook logic runs, every hook
# must run in a throwaway sandbox (HOME / cast.db / cwd / inherited CAST_* dirs),
# never against the caller's live state. Keep in sync with the same block in
# cast-hook-contracts.bats.
# ---------------------------------------------------------------------------

# Probe hook: emits valid <event> hookSpecificOutput iff stdin parses as a JSON object,
# else the literal NOTJSON (which the validator then reports as non-JSON output).
_write_json_probe_hook() { # path event
  sed "s/__EVENT__/$2/" >"$1" <<'SCRIPT'
#!/usr/bin/env bash
payload="$(cat)"
if printf '%s' "$payload" | python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin), dict)' 2>/dev/null; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"__EVENT__","additionalContext":"payload-valid"}}'
else
  printf 'NOTJSON\n'
fi
SCRIPT
  chmod +x "$1"
}

# Probe hook: dirties HOME and cwd, then records what it can see to <out>. The output
# path is baked into the script (hooks run under `env -i`, so no env var can carry it).
# Extra shell appended by the caller via $3 (e.g. removing the sentinel); it may use $PROBE_OUT.
_write_isolation_probe_hook() { # path out [extra-shell]
  sed "s|__PROBE_OUT__|$2|" >"$1" <<'SCRIPT'
#!/usr/bin/env bash
PROBE_OUT=__PROBE_OUT__
cat >/dev/null
mkdir -p "$HOME/.claude" && : >"$HOME/.claude/isolation-marker"
: >"$PWD/cwd-marker"
[ -n "${TMPDIR:-}" ] && : >"$TMPDIR/tmp-marker"
{
  printf 'HOME=%s\n' "$HOME"
  printf 'DB=%s\n' "${CAST_DB_PATH-UNSET}"
  printf 'PWD=%s\n' "$PWD"
  printf 'PROJ=%s\n' "${CLAUDE_PROJECT_DIR-UNSET}"
  printf 'JOURNAL=%s\n' "${CAST_JOURNAL_DIR-UNSET}"
  printf 'GITIDX=%s\n' "${GIT_INDEX_FILE-UNSET}"
  printf 'OSA=%s\n' "$(command -v osascript)"
  printf 'TMPD=%s\n' "${TMPDIR-UNSET}"
  printf 'DBURL=%s\n' "${CAST_DB_URL-UNSET}"
  printf 'VAULT=%s\n' "${CAST_JOURNAL_VAULT-UNSET}"
  printf 'BASHENV=%s\n' "${BASH_ENV-UNSET}"
  printf 'LCALL=%s\n' "${LC_ALL-UNSET}"
  printf 'TOPLEVEL=%s\n' "$(git rev-parse --show-toplevel 2>/dev/null || echo NOREPO)"
} >"$PROBE_OUT"
SCRIPT
  [ -n "${3:-}" ] && printf '%s\n' "$3" >>"$1"
  chmod +x "$1"
}

_write_probe_settings() { # path event hook-basename
  printf '{"hooks":{"%s":[{"id":"probe","hooks":[{"type":"command","command":"bash ~/.claude/scripts/%s"}]}]}}\n' "$2" "$3" >"$1"
}

_probe_field() { # file key
  grep "^$2=" "$1" | cut -d= -f2-
}

@test "validate-all: a hook receives its event's synthetic payload as VALID JSON" {
  local fakerepo="$TEST_TMPDIR/fr_v2a" fake_home="$TEST_TMPDIR/fh_v2a"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude"
  _write_json_probe_hook "$fakerepo/scripts/json-probe.sh" SessionEnd
  _write_probe_settings "$fakerepo/settings.json" SessionEnd json-probe.sh

  run env HOME="$fake_home" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success
  assert_output --partial "[ok] probe (SessionEnd)"
  refute_output --partial "non-JSON output"
}

@test "validate-all: an event with no synthetic payload still gets '{}' (valid JSON)" {
  local fakerepo="$TEST_TMPDIR/fr_v2b" fake_home="$TEST_TMPDIR/fh_v2b"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude"
  _write_json_probe_hook "$fakerepo/scripts/json-probe.sh" Notification
  _write_probe_settings "$fakerepo/settings.json" Notification json-probe.sh

  run env HOME="$fake_home" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success
  assert_output --partial "[ok] probe (Notification)"
}

@test "validate-all: hooks run in a sandbox — real HOME, repo and cwd untouched; inherited CAST_*/GIT_* dirs unset" {
  local fakerepo="$TEST_TMPDIR/fr_v2c" fake_home="$TEST_TMPDIR/fh_v2c"
  local tmpd="$TEST_TMPDIR/tmpd_v2c" invoke="$TEST_TMPDIR/invoke_v2c" out="$TEST_TMPDIR/probe_v2c.out"
  _setup_fake_repo "$fakerepo"
  local vault="$TEST_TMPDIR/vault_v2c" bashenv="$TEST_TMPDIR/bashenv_v2c.sh"
  mkdir -p "$fake_home/.claude" "$tmpd" "$invoke" "$vault"
  : >"$bashenv"
  _write_isolation_probe_hook "$fakerepo/scripts/iso-probe.sh" "$out"
  _write_probe_settings "$fakerepo/settings.json" SessionEnd iso-probe.sh

  cd "$invoke"
  run env HOME="$fake_home" TMPDIR="$tmpd" \
    CAST_JOURNAL_DIR="$TEST_TMPDIR/live-journal" GIT_INDEX_FILE="$TEST_TMPDIR/live-index" \
    CAST_DB_URL="sqlite:///$TEST_TMPDIR/live.db" CAST_JOURNAL_VAULT="$vault" BASH_ENV="$bashenv" LC_ALL=C \
    bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success

  # nothing the hook wrote reached the caller's HOME, the repo, or the caller's cwd
  [ ! -e "$fake_home/.claude/isolation-marker" ]
  [ ! -e "$fakerepo/.claude/isolation-marker" ]
  [ ! -e "$invoke/cwd-marker" ]

  # everything the hook saw lives under the validator's own temp dir
  local sbx
  sbx="$(cd "$tmpd" && pwd -P)"
  [[ "$(_probe_field "$out" HOME)" == "$sbx"/cast-validate-home.* ]]
  [ "$(_probe_field "$out" DB)" = "$(_probe_field "$out" HOME)/.claude/cast.db" ]
  [ "$(_probe_field "$out" PWD)" = "$(_probe_field "$out" HOME)/work" ]
  [ "$(_probe_field "$out" PROJ)" = "$(_probe_field "$out" HOME)/work" ]
  [ "$(_probe_field "$out" OSA)" = "$(_probe_field "$out" HOME)/shim/osascript" ]
  # inherited live-state pointers are gone inside the hook
  [ "$(_probe_field "$out" JOURNAL)" = "UNSET" ]
  [ "$(_probe_field "$out" GITIDX)" = "UNSET" ]
  [ "$(_probe_field "$out" DBURL)" = "UNSET" ]
  [ "$(_probe_field "$out" VAULT)" = "UNSET" ]
  [ "$(_probe_field "$out" BASHENV)" = "UNSET" ]
  # the hook's temp dir is the sandbox's, not the caller's; allowlisted locale passes through
  [ "$(_probe_field "$out" TMPD)" = "$(_probe_field "$out" HOME)/tmp" ]
  [ "$(_probe_field "$out" LCALL)" = "C" ]
  [ ! -e "$tmpd/tmp-marker" ]
  [ -z "$(ls -A "$vault")" ]
}

@test "validate-all: the sandbox is removed on exit (positive control: the hook ran inside it)" {
  local fakerepo="$TEST_TMPDIR/fr_v2d" fake_home="$TEST_TMPDIR/fh_v2d"
  local tmpd="$TEST_TMPDIR/tmpd_v2d" out="$TEST_TMPDIR/probe_v2d.out"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude" "$tmpd"
  _write_isolation_probe_hook "$fakerepo/scripts/iso-probe.sh" "$out"
  _write_probe_settings "$fakerepo/settings.json" SessionEnd iso-probe.sh

  run env HOME="$fake_home" TMPDIR="$tmpd" \
    bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success

  local seen
  seen="$(_probe_field "$out" HOME)"
  [[ "$seen" == "$(cd "$tmpd" && pwd -P)"/cast-validate-home.* ]] # it existed...
  [ ! -e "$seen" ]                                                 # ...and is gone
  [ "$(find "$tmpd" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
}

@test "validate-all: cleanup refuses a sandbox that lost its sentinel (fail-closed)" {
  local fakerepo="$TEST_TMPDIR/fr_v2e" fake_home="$TEST_TMPDIR/fh_v2e"
  local tmpd="$TEST_TMPDIR/tmpd_v2e" out="$TEST_TMPDIR/probe_v2e.out"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude" "$tmpd"
  _write_isolation_probe_hook "$fakerepo/scripts/iso-probe.sh" "$out" 'rm -f "$HOME/.cast-test-home"'
  _write_probe_settings "$fakerepo/settings.json" SessionEnd iso-probe.sh

  run env HOME="$fake_home" TMPDIR="$tmpd" \
    bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success

  # no sentinel -> the validator must NOT delete it (left for a human; teardown removes $TEST_TMPDIR)
  [ -d "$(_probe_field "$out" HOME)" ]
}

@test "validate-all --source: executes the sandbox COPY of the repo script (its dirname-\$0 is inside the sandbox, not the repo)" {
  local fakerepo="$TEST_TMPDIR/fr_v2f" fake_home="$TEST_TMPDIR/fh_v2f"
  local tmpd="$TEST_TMPDIR/tmpd_v2f" out="$TEST_TMPDIR/probe_v2f.out"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude" "$tmpd"
  _write_isolation_probe_hook "$fakerepo/scripts/iso-probe.sh" "$out" 'printf "SELFDIR=%s\n" "$(cd "$(dirname "$0")" && pwd)" >>"$PROBE_OUT"'
  _write_probe_settings "$fakerepo/settings.json" SessionEnd iso-probe.sh

  run env HOME="$fake_home" TMPDIR="$tmpd" \
    bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success

  # the hook ran from the seeded copy inside the sandbox...
  [ "$(_probe_field "$out" SELFDIR)" = "$(_probe_field "$out" HOME)/.claude/scripts" ]
  # ...not from the repo it was seeded from
  [ "$(_probe_field "$out" SELFDIR)" != "$fakerepo/scripts" ]
}

@test "validate-all --source: a symlink in the seed source fails closed (exit 2) and leaves no sandbox" {
  local fakerepo="$TEST_TMPDIR/fr_v2g" fake_home="$TEST_TMPDIR/fh_v2g" tmpd="$TEST_TMPDIR/tmpd_v2g"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude" "$tmpd"
  _write_json_probe_hook "$fakerepo/scripts/json-probe.sh" SessionEnd
  _write_probe_settings "$fakerepo/settings.json" SessionEnd json-probe.sh
  ln -s "$TEST_TMPDIR" "$fakerepo/scripts/evil-link" # a dereferencing copy would pull this tree in

  run env HOME="$fake_home" TMPDIR="$tmpd" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] seed source contains symlinks:"
  assert_output --partial "evil-link"
  [ "$(find "$tmpd" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
}

@test "validate-all: git discovery in a hook cannot escape into a caller TMPDIR that is inside a work tree" {
  local fakerepo="$TEST_TMPDIR/fr_v2h" fake_home="$TEST_TMPDIR/fh_v2h"
  local callerrepo="$TEST_TMPDIR/callerrepo_v2h" out="$TEST_TMPDIR/probe_v2h.out"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude" "$callerrepo/tmp"
  HOME="$fake_home" git init -q "$callerrepo"
  _write_isolation_probe_hook "$fakerepo/scripts/iso-probe.sh" "$out"
  _write_probe_settings "$fakerepo/settings.json" SessionEnd iso-probe.sh

  run env HOME="$fake_home" TMPDIR="$callerrepo/tmp" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  assert_success
  [ "$(_probe_field "$out" TOPLEVEL)" = "NOREPO" ]
}

@test "validate-all --source: a symlink that appears in the sandbox copy AFTER seeding fails closed before any hook runs" {
  local fakerepo="$TEST_TMPDIR/fr_v2i" fake_home="$TEST_TMPDIR/fh_v2i" tmpd="$TEST_TMPDIR/tmpd_v2i"
  local shimdir="$TEST_TMPDIR/shim_v2i" out="$TEST_TMPDIR/probe_v2i.out"
  _setup_fake_repo "$fakerepo"
  mkdir -p "$fake_home/.claude" "$tmpd" "$shimdir"
  _write_isolation_probe_hook "$fakerepo/scripts/iso-probe.sh" "$out"
  _write_probe_settings "$fakerepo/settings.json" SessionEnd iso-probe.sh
  # tar shim: real tar, then (extract side only) plant a symlink in the sandbox copy —
  # stands in for the source changing between the pre-check and the copy (TOCTOU)
  printf '#!/bin/sh\n"%s" "$@" || exit $?\ncase "$1" in -xf) ln -s /nonexistent planted-link ;; esac\n' "$(command -v tar)" >"$shimdir/tar"
  chmod +x "$shimdir/tar"

  run env HOME="$fake_home" TMPDIR="$tmpd" PATH="$shimdir:$PATH" bash "$fakerepo/scripts/cast-validate-all-hooks.sh" --source
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] seed source contains symlinks:"
  assert_output --partial "planted-link"
  [ ! -e "$out" ] # no hook ran
  [ "$(find "$tmpd" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
}
