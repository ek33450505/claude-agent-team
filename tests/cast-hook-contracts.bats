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

# ---------------------------------------------------------------------------
# V2 (2026-10-05): hooks must receive VALID JSON on stdin — the old
# `${!payload_var:-{}}` ended at the first '}' and appended a stray one, so every
# hook was validated on INVALID JSON — and, now that real hook logic runs, every hook
# must run in a throwaway sandbox (HOME / cast.db / cwd / inherited CAST_* dirs),
# never against the caller's live state. Keep in sync with the same block in
# cast-validate-all-hooks.bats.
# ---------------------------------------------------------------------------

# Sandbox repo ($PS): validator + its guard lib + settings.json registering ONE hook `probe`
# for $1 (event) through the installed-path form, pointing at scripts/$2.
_probe_repo() { # event hook-basename
  PS="$BATS_TEST_TMPDIR/probe-repo"
  mkdir -p "$PS/scripts"
  cp "$VALIDATOR" "$PS/scripts/cast-validate-hook-contracts.sh"
  cp "$REPO_DIR/scripts/cast-guard-lib.sh" "$PS/scripts/cast-guard-lib.sh"
  printf '{"hooks":{"%s":[{"id":"probe","hooks":[{"type":"command","command":"bash ~/.claude/scripts/%s"}]}]}}\n' "$1" "$2" >"$PS/settings.json"
}

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

_probe_field() { # file key
  grep "^$2=" "$1" | cut -d= -f2-
}

@test "validator: a hook receives its event's synthetic payload as VALID JSON" {
  _probe_repo SessionEnd json-probe.sh
  _write_json_probe_hook "$PS/scripts/json-probe.sh" SessionEnd

  run env HOME="$HOME" bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 0 ]
  assert_output --partial "[ok] probe (SessionEnd)"
  refute_output --partial "non-JSON output"
}

@test "validator: an event with no synthetic payload still gets '{}' (valid JSON)" {
  _probe_repo Notification json-probe.sh
  _write_json_probe_hook "$PS/scripts/json-probe.sh" Notification

  run env HOME="$HOME" bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 0 ]
  assert_output --partial "[ok] probe (Notification)"
}

@test "validator: hooks run in a sandbox — real HOME, repo and cwd untouched; inherited CAST_*/GIT_* dirs unset" {
  local tmpd="$BATS_TEST_TMPDIR/tmpd" invoke="$BATS_TEST_TMPDIR/invoke" out="$BATS_TEST_TMPDIR/probe.out"
  local vault="$BATS_TEST_TMPDIR/vault" bashenv="$BATS_TEST_TMPDIR/bashenv.sh"
  mkdir -p "$tmpd" "$invoke" "$vault"
  : >"$bashenv"
  _probe_repo SessionEnd iso-probe.sh
  _write_isolation_probe_hook "$PS/scripts/iso-probe.sh" "$out"

  cd "$invoke"
  run env HOME="$HOME" TMPDIR="$tmpd" \
    CAST_JOURNAL_DIR="$BATS_TEST_TMPDIR/live-journal" GIT_INDEX_FILE="$BATS_TEST_TMPDIR/live-index" \
    CAST_DB_URL="sqlite:///$BATS_TEST_TMPDIR/live.db" CAST_JOURNAL_VAULT="$vault" BASH_ENV="$bashenv" LC_ALL=C \
    bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 0 ]

  # nothing the hook wrote reached the caller's HOME, the repo, or the caller's cwd
  [ ! -e "$HOME/.claude/isolation-marker" ]
  [ ! -e "$PS/.claude/isolation-marker" ]
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

@test "validator: the sandbox is removed on exit (positive control: the hook ran inside it)" {
  local tmpd="$BATS_TEST_TMPDIR/tmpd" out="$BATS_TEST_TMPDIR/probe.out"
  mkdir -p "$tmpd"
  _probe_repo SessionEnd iso-probe.sh
  _write_isolation_probe_hook "$PS/scripts/iso-probe.sh" "$out"

  run env HOME="$HOME" TMPDIR="$tmpd" \
    bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 0 ]

  local seen
  seen="$(_probe_field "$out" HOME)"
  [[ "$seen" == "$(cd "$tmpd" && pwd -P)"/cast-validate-home.* ]] # it existed...
  [ ! -e "$seen" ]                                                 # ...and is gone
  [ "$(find "$tmpd" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
}

@test "validator: cleanup refuses a sandbox that lost its sentinel (fail-closed)" {
  local tmpd="$BATS_TEST_TMPDIR/tmpd" out="$BATS_TEST_TMPDIR/probe.out"
  mkdir -p "$tmpd"
  _probe_repo SessionEnd iso-probe.sh
  _write_isolation_probe_hook "$PS/scripts/iso-probe.sh" "$out" 'rm -f "$HOME/.cast-test-home"'

  run env HOME="$HOME" TMPDIR="$tmpd" \
    bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 0 ]

  # no sentinel -> the validator must NOT delete it (left for a human; BATS cleans $BATS_TEST_TMPDIR)
  [ -d "$(_probe_field "$out" HOME)" ]
}

@test "validator (runtime mode): executes the SEEDED copy of an installed hook, not the real one" {
  local out="$BATS_TEST_TMPDIR/probe.out"
  _probe_repo SessionEnd iso-probe.sh
  # installed copy lives under the (temp) HOME only; it records which file ran
  mkdir -p "$HOME/.claude/scripts"
  _write_isolation_probe_hook "$HOME/.claude/scripts/iso-probe.sh" "$out" 'printf "SELF=%s\n" "$0" >>"$PROBE_OUT"'
  cp "$PS/settings.json" "$HOME/.claude/settings.json"

  run env HOME="$HOME" TMPDIR="$BATS_TEST_TMPDIR" \
    bash "$PS/scripts/cast-validate-hook-contracts.sh"
  [ "$status" -eq 0 ]
  [ "$(_probe_field "$out" SELF)" = "$(_probe_field "$out" HOME)/.claude/scripts/iso-probe.sh" ]
  [ ! -e "$HOME/.claude/isolation-marker" ]
}

@test "validator --source: executes the sandbox COPY of the repo script (its dirname-\$0 is inside the sandbox, not the repo)" {
  local tmpd="$BATS_TEST_TMPDIR/tmpd" out="$BATS_TEST_TMPDIR/probe.out"
  mkdir -p "$tmpd"
  _probe_repo SessionEnd iso-probe.sh
  _write_isolation_probe_hook "$PS/scripts/iso-probe.sh" "$out" 'printf "SELFDIR=%s\n" "$(cd "$(dirname "$0")" && pwd)" >>"$PROBE_OUT"'

  run env HOME="$HOME" TMPDIR="$tmpd" \
    bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 0 ]

  # the hook ran from the seeded copy inside the sandbox...
  [ "$(_probe_field "$out" SELFDIR)" = "$(_probe_field "$out" HOME)/.claude/scripts" ]
  # ...not from the repo it was seeded from
  [ "$(_probe_field "$out" SELFDIR)" != "$PS/scripts" ]
}

@test "validator --source: a symlink in the seed source fails closed (exit 2) and leaves no sandbox" {
  local tmpd="$BATS_TEST_TMPDIR/tmpd"
  mkdir -p "$tmpd"
  _probe_repo SessionEnd json-probe.sh
  _write_json_probe_hook "$PS/scripts/json-probe.sh" SessionEnd
  ln -s "$BATS_TEST_TMPDIR" "$PS/scripts/evil-link" # a dereferencing copy would pull this tree in

  run env HOME="$HOME" TMPDIR="$tmpd" bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] seed source contains symlinks:"
  assert_output --partial "evil-link"
  [ "$(find "$tmpd" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
}

@test "validator: git discovery in a hook cannot escape into a caller TMPDIR that is inside a work tree" {
  local callerrepo="$BATS_TEST_TMPDIR/callerrepo" out="$BATS_TEST_TMPDIR/probe.out"
  mkdir -p "$callerrepo/tmp"
  git init -q "$callerrepo"
  _probe_repo SessionEnd iso-probe.sh
  _write_isolation_probe_hook "$PS/scripts/iso-probe.sh" "$out"

  run env HOME="$HOME" TMPDIR="$callerrepo/tmp" bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 0 ]
  [ "$(_probe_field "$out" TOPLEVEL)" = "NOREPO" ]
}

@test "validator --source: a symlink that appears in the sandbox copy AFTER seeding fails closed before any hook runs" {
  local tmpd="$BATS_TEST_TMPDIR/tmpd" shimdir="$BATS_TEST_TMPDIR/shim" out="$BATS_TEST_TMPDIR/probe.out"
  mkdir -p "$tmpd" "$shimdir"
  _probe_repo SessionEnd iso-probe.sh
  _write_isolation_probe_hook "$PS/scripts/iso-probe.sh" "$out"
  # tar shim: real tar, then (extract side only) plant a symlink in the sandbox copy —
  # stands in for the source changing between the pre-check and the copy (TOCTOU)
  printf '#!/bin/sh\n"%s" "$@" || exit $?\ncase "$1" in -xf) ln -s /nonexistent planted-link ;; esac\n' "$(command -v tar)" >"$shimdir/tar"
  chmod +x "$shimdir/tar"

  run env HOME="$HOME" TMPDIR="$tmpd" PATH="$shimdir:$PATH" bash "$PS/scripts/cast-validate-hook-contracts.sh" --source
  [ "$status" -eq 2 ]
  assert_output --partial "[fail] seed source contains symlinks:"
  assert_output --partial "planted-link"
  [ ! -e "$out" ] # no hook ran
  [ "$(find "$tmpd" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
}
