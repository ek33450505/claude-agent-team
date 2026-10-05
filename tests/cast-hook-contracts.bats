#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_DIR/scripts/cast-validate-hook-contracts.sh"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  export TEST_TMPDIR="$(mktemp -d /tmp/cast-hook-contracts-test.XXXXXXXX)"
  # Seed the isolated HOME with the repo hook scripts so Test 1's `--source`
  # validation resolves ~/.claude/scripts/* into the temp HOME and executes
  # the seeded copies there — never the real ~/.claude (mirrors tests/run.sh).
  mkdir -p "$HOME/.claude/scripts"
  cp "$REPO_DIR"/scripts/*.sh "$HOME/.claude/scripts/" 2>/dev/null || true
  chmod +x "$HOME/.claude/scripts/"*.sh 2>/dev/null || true
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a fixture hook script that emits the given JSON content
_write_fixture_hook() {
  local path="$1"
  local json_content="$2"
  # Use python to write the script so quoting is handled safely
  export _FIXTURE_PATH="$path"
  export _FIXTURE_JSON="$json_content"
  python3 - <<'PYEOF'
import os
path = os.environ["_FIXTURE_PATH"]
json_content = os.environ["_FIXTURE_JSON"]
script = f'''#!/usr/bin/env bash
if [[ "${{CLAUDE_SUBPROCESS:-0}}" == "1" ]]; then exit 0; fi
cat <<'JSONEOF'
{json_content}
JSONEOF
'''
with open(path, "w") as f:
    f.write(script)
os.chmod(path, 0o755)
PYEOF
}

# Write a fixture hook that emits nothing (logging-only)
_write_logging_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
# Logging-only: no stdout output
exit 0
SCRIPT
  chmod +x "$path"
}

# Write a fixture hook that emits plain text (not JSON)
_write_plaintext_hook() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi
echo "plain text not JSON"
SCRIPT
  chmod +x "$path"
}

# Write a minimal synthetic settings.json with one SessionStart hook
_write_synthetic_settings() {
  local settings_path="$1"
  local script_path="$2"
  export _SETTINGS_PATH="$settings_path"
  export _SCRIPT_PATH="$script_path"
  python3 - <<'PYEOF'
import json, os
settings_path = os.environ["_SETTINGS_PATH"]
script_path = os.environ["_SCRIPT_PATH"]
data = {
    "hooks": {
        "SessionStart": [
            {
                "id": "test-fixture-hook",
                "hooks": [
                    {"type": "command", "command": f"bash {script_path}", "timeout": 3}
                ]
            }
        ]
    }
}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# Run validator with a fake HOME containing the given settings.json
_run_validator_with_settings() {
  local settings_path="$1"
  local fake_home="$TEST_TMPDIR/fakehome_$$_${RANDOM}"
  mkdir -p "$fake_home/.claude"
  cp "$settings_path" "$fake_home/.claude/settings.json"
  HOME="$fake_home" bash "$VALIDATOR" 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: validator passes against current source settings.json
# ---------------------------------------------------------------------------

@test "validator passes against current source settings.json" {
  # Accept WARN (exit 1) for missing ~/.claude/scripts/ entries in source context
  # but not ERROR (exit 2)
  run bash "$VALIDATOR" --source
  [ "$status" -le 1 ]
  [[ "$output" =~ "Hook contract validation:" ]]
}

# ---------------------------------------------------------------------------
# Test 2: validator catches wrong hookEventName
# ---------------------------------------------------------------------------

@test "validator catches wrong hookEventName" {
  local fixture_script="$TEST_TMPDIR/wrong-event-hook.sh"
  local settings_file="$TEST_TMPDIR/settings.json"

  # Fixture emits hookSpecificOutput with wrong hookEventName
  _write_fixture_hook "$fixture_script" \
    '{"hookSpecificOutput":{"hookEventName":"WrongEvent","additionalContext":""}}'
  _write_synthetic_settings "$settings_file" "$fixture_script"

  local output
  output="$(_run_validator_with_settings "$settings_file" || true)"
  local exit_status=$?

  # Must exit 2 (ERROR)
  local actual_exit
  actual_exit=$(HOME="$(mktemp -d)" 2>/dev/null; \
    fake_home="$TEST_TMPDIR/fh_wrong_$$"; \
    mkdir -p "$fake_home/.claude"; \
    cp "$settings_file" "$fake_home/.claude/settings.json"; \
    HOME="$fake_home" bash "$VALIDATOR" 2>&1; echo "EXIT:$?") || true

  # Simpler: run directly and capture
  local fake_home="$TEST_TMPDIR/fh_wrong"
  mkdir -p "$fake_home/.claude"
  cp "$settings_file" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR"
  assert_failure
  [ "$status" -eq 2 ]

  # Combined stdout+stderr should mention WrongEvent
  local combined
  combined="$(env HOME="$fake_home" bash "$VALIDATOR" 2>&1 || true)"
  [[ "$combined" =~ "WrongEvent" ]]
}

# ---------------------------------------------------------------------------
# Test 3: validator catches unknown top-level key (yesterday's bug class)
# ---------------------------------------------------------------------------

@test "validator catches unknown top-level key (type/content shape)" {
  local fixture_script="$TEST_TMPDIR/bad-shape-hook.sh"
  local settings_file="$TEST_TMPDIR/settings.json"

  # Fixture emits {type:'context',content:'...'} — the bug from 2026-05-05
  _write_fixture_hook "$fixture_script" \
    '{"type":"context","content":"some injected text"}'
  _write_synthetic_settings "$settings_file" "$fixture_script"

  local fake_home="$TEST_TMPDIR/fh_badshape"
  mkdir -p "$fake_home/.claude"
  cp "$settings_file" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR"
  # Must be at least exit 1 (WARN for unknown key)
  [ "$status" -ge 1 ]

  local combined
  combined="$(env HOME="$fake_home" bash "$VALIDATOR" 2>&1 || true)"
  [[ "$combined" =~ "unknown key" ]]
}

# ---------------------------------------------------------------------------
# Test 4: validator handles empty-stdout logging hooks gracefully
# ---------------------------------------------------------------------------

@test "validator handles empty-stdout logging hooks gracefully" {
  local fixture_script="$TEST_TMPDIR/logging-hook.sh"
  local settings_file="$TEST_TMPDIR/settings.json"

  _write_logging_hook "$fixture_script"
  _write_synthetic_settings "$settings_file" "$fixture_script"

  local fake_home="$TEST_TMPDIR/fh_logging"
  mkdir -p "$fake_home/.claude"
  cp "$settings_file" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR"
  assert_success  # exit 0

  local combined
  combined="$(env HOME="$fake_home" bash "$VALIDATOR" 2>&1)"
  [[ "$combined" =~ "[ok]" ]]
  [[ "$combined" =~ "logging-only" ]]
}

# ---------------------------------------------------------------------------
# Test 5: validator handles non-JSON output as ERROR
# ---------------------------------------------------------------------------

@test "validator handles non-JSON output as ERROR" {
  local fixture_script="$TEST_TMPDIR/plain-text-hook.sh"
  local settings_file="$TEST_TMPDIR/settings.json"

  _write_plaintext_hook "$fixture_script"
  _write_synthetic_settings "$settings_file" "$fixture_script"

  local fake_home="$TEST_TMPDIR/fh_plaintext"
  mkdir -p "$fake_home/.claude"
  cp "$settings_file" "$fake_home/.claude/settings.json"

  run env HOME="$fake_home" bash "$VALIDATOR"
  assert_failure  # exit 2 for ERROR
  [ "$status" -eq 2 ]

  local combined
  combined="$(env HOME="$fake_home" bash "$VALIDATOR" 2>&1 || true)"
  [[ "$combined" =~ "[fail]" ]]
}

# ---------------------------------------------------------------------------
# Test 6: Task|Agent matcher for cast-pretool-dispatch
# ---------------------------------------------------------------------------

@test "cast-pretool-dispatch matcher includes both Task and Agent" {
  # The F2 dispatch-capture hook must match BOTH "Task" (older Claude Code)
  # and "Agent" (current Claude Code) subagent-dispatch tool names.
  # This test ensures the regex matcher never regresses to match only one.
  local settings_file="$REPO_DIR/managed-settings.d/25-hooks-security.json"

  # Extract the matcher regex for cast-pretool-dispatch hook
  local matcher
  matcher=$(python3 -c "
import json
with open('$settings_file') as f:
    data = json.load(f)
hooks = data.get('hooks', {}).get('PreToolUse', [])
for hook in hooks:
    if hook.get('id') == 'cast-pretool-dispatch':
        print(hook.get('matcher', ''))
        break
" 2>/dev/null || echo "")

  # Verify matcher is non-empty
  [ -n "$matcher" ]

  # Verify matcher regex contains both Task and Agent (literal strings in alternation)
  [[ "$matcher" =~ "Task" ]]
  [[ "$matcher" =~ "Agent" ]]
}

# ---------------------------------------------------------------------------
# Test 7: top-level `decision` is validated for EVERY event (2026-10-05).
# Claude Code's hook-output validation accepts only "approve" | "block" and rejects anything else
# at runtime ("decision: Invalid option: expected one of approve|block") - the validator used to
# check Stop (block|continue) and PreToolUse (block|allow, warn only) and pass every other event.
# ---------------------------------------------------------------------------

# Plant a fixture hook (printing $2, or printing nothing when $2 is __silent__) registered under event $1 in a fake HOME, then run the
# validator against it. Sets $status / $output (stdout+stderr merged).
_validate_event_fixture() { # event json
  local event="$1" json="$2"
  local fixture_script="$TEST_TMPDIR/decision-$event-hook.sh"
  local settings_file="$TEST_TMPDIR/decision-$event-settings.json"
  local fake_home="$TEST_TMPDIR/fh_decision_$event"
  if [ "$json" = "__silent__" ]; then
    _write_logging_hook "$fixture_script"
  else
    _write_fixture_hook "$fixture_script" "$json"
  fi
  _CV_EVENT="$event" _SETTINGS_PATH="$settings_file" _SCRIPT_PATH="$fixture_script" python3 - <<'PYEOF'
import json, os
event = os.environ["_CV_EVENT"]
data = {"hooks": {event: [{"id": "decision-fixture-hook", "hooks": [
    {"type": "command", "command": "bash " + os.environ["_SCRIPT_PATH"], "timeout": 3}]}]}}
with open(os.environ["_SETTINGS_PATH"], "w") as f:
    json.dump(data, f)
PYEOF
  mkdir -p "$fake_home/.claude"
  cp "$settings_file" "$fake_home/.claude/settings.json"
  run env HOME="$fake_home" bash "$VALIDATOR"
}

@test "validator FAILS a PreCompact hook that prints decision=allow (Claude Code accepts only approve|block)" {
  _validate_event_fixture PreCompact '{"decision":"allow"}'
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] decision-fixture-hook (PreCompact)"
  assert_output --partial "invalid top-level decision value 'allow'"
  assert_output --partial "approve|block"
}

@test "validator FAILS a Stop hook that prints decision=continue (not an accepted value)" {
  _validate_event_fixture Stop '{"decision":"continue"}'
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] decision-fixture-hook (Stop)"
  assert_output --partial "invalid top-level decision value 'continue'"
}

@test "validator FAILS a PreToolUse hook that prints decision=allow (previously only warned)" {
  _validate_event_fixture PreToolUse '{"decision":"allow"}'
  [ "$status" -eq 2 ]
  assert_output --partial "invalid top-level decision value 'allow'"
}

@test "validator accepts decision=block on PreCompact (control: no invalid-decision failure)" {
  _validate_event_fixture PreCompact '{"decision":"block","reason":"x"}'
  [ "$status" -eq 0 ]
  assert_output --partial "[ok] decision-fixture-hook (PreCompact)"
  refute_output --partial "invalid top-level decision"
}

@test "validator accepts decision=approve on Stop (control: no invalid-decision failure)" {
  _validate_event_fixture Stop '{"decision":"approve"}'
  [ "$status" -eq 0 ]
  refute_output --partial "invalid top-level decision"
}

@test "validator accepts empty stdout on PreCompact (the proceed contract)" {
  _validate_event_fixture PreCompact __silent__
  [ "$status" -eq 0 ]
  assert_output --partial "empty stdout"
}

# ---------------------------------------------------------------------------
# Test 8: --source executes the REPO copy of a hook, not the installed one (2026-10-05).
# settings.json registers hooks as `bash ~/.claude/scripts/<name>` (the INSTALLED path). Under
# --source the validator read the repo settings.json but still executed the installed copy, so a
# stale installed hook failed a correct tree and a working-tree fix/regression was never seen.
# Both directions are probed in a sandbox repo copy: the repo copy and the installed copy
# disagree, and only the one the mode is supposed to run may decide the verdict.
# ---------------------------------------------------------------------------

# Build $PC_SB (sandbox repo: validator + settings.json registering ONE PreCompact hook through the
# installed-path form + scripts/fixture-pc.sh) and $HOME/.claude/scripts/fixture-pc.sh (installed copy).
# Args: repo-copy-json installed-json; "" = that copy prints nothing.
_pc_sandbox() { # repo_json installed_json
  PC_SB="$BATS_TEST_TMPDIR/sandbox-repo"
  mkdir -p "$PC_SB/scripts" "$HOME/.claude/scripts"
  cp "$VALIDATOR" "$PC_SB/scripts/cast-validate-hook-contracts.sh"
  printf '%s\n' '{"hooks":{"PreCompact":[{"id":"fixture-pc","hooks":[{"type":"command","command":"bash ~/.claude/scripts/fixture-pc.sh"}]}]}}' > "$PC_SB/settings.json"
  if [ -n "$1" ]; then _write_fixture_hook "$PC_SB/scripts/fixture-pc.sh" "$1"; else _write_logging_hook "$PC_SB/scripts/fixture-pc.sh"; fi
  if [ -n "$2" ]; then _write_fixture_hook "$HOME/.claude/scripts/fixture-pc.sh" "$2"; else _write_logging_hook "$HOME/.claude/scripts/fixture-pc.sh"; fi
}
_pc_validate() { # extra flags...
  run env HOME="$HOME" bash "$PC_SB/scripts/cast-validate-hook-contracts.sh" "$@"
}

@test "validator --source runs the REPO copy: clean repo copy + stale installed copy (prints allow) -> no error" {
  _pc_sandbox '' '{"decision":"allow"}'
  _pc_validate --source
  [ "$status" -le 1 ]
  assert_output --partial "[ok] fixture-pc (PreCompact)"
  refute_output --partial "invalid top-level decision"
}

@test "validator --source runs the REPO copy: bad repo copy (prints allow) + clean installed copy -> error" {
  _pc_sandbox '{"decision":"allow"}' ''
  _pc_validate --source
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] fixture-pc (PreCompact)"
  assert_output --partial "invalid top-level decision value 'allow'"
}

@test "validator without --source still runs the INSTALLED copy (default mode unchanged)" {
  _pc_sandbox '' '{"decision":"allow"}'
  # default mode reads $HOME/.claude/settings.json, not the repo's
  cp "$PC_SB/settings.json" "$HOME/.claude/settings.json"
  _pc_validate
  [ "$status" -eq 2 ]
  assert_output --partial "invalid top-level decision value 'allow'"
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

@test "validator escapes a hook-controlled decision value (no forged [ok] line in the log)" {
  _pc_sandbox '{"decision":"allow\n[ok] forged"}' ''
  _pc_validate --source
  [ "$status" -eq 2 ]
  # the newline is escaped (repr), so the value stays on ONE line...
  assert_output --partial '\n[ok] forged'
  # ...and no output line may start with a forged [ok] marker
  _refute_forged_ok_line
}

@test "validator escapes a hook-controlled unknown KEY (no forged [ok] line in the log)" {
  _pc_sandbox '{"zz\n[ok] forged-via-key":1}' ''
  _pc_validate --source
  # the key is reported (unknown key warn) with its newline escaped, on ONE line...
  assert_output --partial 'unknown key'
  assert_output --partial '\n[ok] forged-via-key'
  _refute_forged_ok_line
}

@test "validator escapes a hook-controlled hookEventName (no forged [ok] line in the log)" {
  _pc_sandbox '{"hookSpecificOutput":{"hookEventName":"x\n[ok] forged-via-event","additionalContext":""}}' ''
  _pc_validate --source
  [ "$status" -eq 2 ]
  assert_output --partial "wrong hookEventName"
  assert_output --partial '\n[ok] forged-via-event'
  _refute_forged_ok_line
}
