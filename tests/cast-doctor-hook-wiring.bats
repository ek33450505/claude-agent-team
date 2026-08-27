#!/usr/bin/env bats

# Tests for cast doctor check #23: Hook double-wiring / stale sentinel
# Covers:
# 1. Dual install + missing sentinel → WARN
# 2. Dual install + valid sentinel → INFO
# 3. Plugin only → no risk
# 4. Install.sh only → no risk
# 5. Stale sentinel → WARN

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  export CAST_CONFIG_DIR="${HOME}/.claude/config"
  mkdir -p "$CAST_CONFIG_DIR"
  mkdir -p "${HOME}/.claude/cast/events"
}

teardown() {
  teardown_temp_home
}

# Helper to create a mock claude CLI that reports the cast plugin status
mock_claude_cli() {
  local plugin_present="$1"  # 0 = plugin absent, 1 = plugin present

  cat > "${HOME}/claude" <<MOCKSCRIPT
#!/bin/bash
if [[ "\$1" == "plugin" ]] && [[ "\$2" == "list" ]]; then
  if [ "$plugin_present" -eq 1 ]; then
    echo "cast (plugin)"
  fi
  exit 0
fi
exit 1
MOCKSCRIPT
  chmod +x "${HOME}/claude"
  export PATH="${HOME}:$PATH"
}

# Helper to create settings.json with cast-* hooks
create_settings_with_hooks() {
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": {
      "hooks": [
        {
          "command": "bash ~/.claude/scripts/cast-hook-example.sh"
        }
      ]
    }
  }
}
JSON
}

# Helper to create settings.json without cast-* hooks
create_settings_without_hooks() {
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SomeOtherHook": {
      "hooks": [
        {
          "command": "bash ~/.claude/scripts/other-hook.sh"
        }
      ]
    }
  }
}
JSON
}

# Helper to create an empty settings.json
create_empty_settings() {
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {}
}
JSON
}

@test "check 23: dual-install + missing-sentinel reports WARN" {
  mock_claude_cli 1  # plugin present
  create_settings_with_hooks  # install.sh hooks present
  # Do NOT create the sentinel file

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "double-fire risk" ]]
  [[ "$output" =~ "cast-hook-owner sentinel MISSING" ]]
  [[ "$output" =~ "Fix: touch" ]]
}

@test "check 23: dual-install + valid-sentinel reports INFO" {
  mock_claude_cli 1  # plugin present
  create_settings_with_hooks  # install.sh hooks present
  # Create the sentinel file
  touch "${CAST_CONFIG_DIR}/cast-hook-owner"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "dual install detected" ]]
  [[ "$output" =~ "plugin hooks defer to install.sh via cast-hook-owner sentinel" ]]
}

@test "check 23: plugin-only reports no risk" {
  mock_claude_cli 1  # plugin present
  create_empty_settings  # NO install.sh hooks
  # No sentinel

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "no double-fire risk" ]]
  [[ ! "$output" =~ "stale" ]]
}

@test "check 23: install.sh-only reports no risk" {
  mock_claude_cli 0  # plugin NOT present
  create_settings_with_hooks  # install.sh hooks present
  # No sentinel

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "no double-fire risk" ]]
}

@test "check 23: stale-sentinel reports WARN" {
  mock_claude_cli 0  # plugin NOT present
  create_empty_settings  # NO install.sh hooks
  # Sentinel exists but hooks don't
  touch "${CAST_CONFIG_DIR}/cast-hook-owner"

  run bash bin/cast doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" =~ "stale cast-hook-owner sentinel" ]]
  [[ "$output" =~ "plugin hooks are deferring but no install.sh hooks found" ]]
  [[ "$output" =~ "Fix: rm" ]]
}
