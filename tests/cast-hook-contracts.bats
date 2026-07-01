#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_DIR/scripts/cast-validate-hook-contracts.sh"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  export TEST_TMPDIR="$(mktemp -d /tmp/cast-hook-contracts-test.XXXXXXXX)"
  export ORIG_HOME="$HOME"
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
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
