#!/usr/bin/env bats
# cast-lint-hook-wiring.bats — BATS tests for cast-lint-hook-wiring.py
#
# All tests use an isolated temp HOME and fixture settings files so they
# never consult the live ~/.claude or modify the real repo.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_PY="$REPO_DIR/scripts/cast-lint-hook-wiring.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  FIXTURE_DIR="$(mktemp -d)"
  FIXTURE_FRAGS="${FIXTURE_DIR}/frags"
  mkdir -p "${FIXTURE_FRAGS}"
}

teardown() {
  rm -rf "${FIXTURE_DIR}"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_settings() {
  # $1 = path, $2 = JSON string
  printf '%s\n' "$2" > "$1"
}

_settings_with_cmd() {
  # Build a settings.json with one hook entry for the given event and command
  local event="$1" cmd="$2"
  printf '{"hooks":{"%s":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "${event}" "${cmd}"
}

_frag_with_cmd() {
  local event="$1" cmd="$2"
  printf '{"hooks":{"%s":[{"type":"command","command":"%s"}]}}\n' \
    "${event}" "${cmd}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "pass on the real repo (no duplicate wiring in current settings)" {
  run python3 "${LINT_PY}"
  assert_success
}

@test "pass when settings.json is absent" {
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/nonexistent.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_success
}

@test "pass when managed-settings.d is absent" {
  _write_settings "${FIXTURE_DIR}/settings.json" \
    "$(_settings_with_cmd "PreToolUse" "bash ~/.claude/scripts/pre-tool-guard.sh")"
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_DIR}/nonexistent-frags" \
         python3 "${LINT_PY}"
  assert_success
}

@test "pass when settings.json is empty object" {
  _write_settings "${FIXTURE_DIR}/settings.json" '{}'
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_success
}

@test "fail when same basename appears twice in one settings.json event" {
  # Duplicate: cast-user-prompt-hook.sh wired twice under UserPromptSubmit
  _write_settings "${FIXTURE_DIR}/settings.json" \
    '{"hooks":{"UserPromptSubmit":[
       {"hooks":[{"type":"command","command":"bash ~/.claude/scripts/cast-user-prompt-hook.sh"}]},
       {"hooks":[{"type":"command","command":"bash ~/.claude/scripts/cast-user-prompt-hook.sh"}]}
     ]}}'
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "cast-user-prompt-hook.sh"
  assert_output --partial "UserPromptSubmit"
}

@test "pass when same basename appears in two DIFFERENT fragment files (by design — not a dup)" {
  # managed-settings.d fragments are canonical; settings.json is a generated merge.
  # The same script appearing in two separate fragment files is NOT a duplicate —
  # each fragment is an independent wiring source and they don't overlap at runtime.
  _write_settings "${FIXTURE_DIR}/settings.json" '{}'
  _write_settings "${FIXTURE_FRAGS}/10.json" \
    "$(_frag_with_cmd "PostToolUse" "bash ~/.claude/scripts/post-tool-hook.sh")"
  _write_settings "${FIXTURE_FRAGS}/20.json" \
    "$(_frag_with_cmd "PostToolUse" "bash ~/.claude/scripts/post-tool-hook.sh")"
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_success
}

@test "pass when same basename in DIFFERENT events (not a duplicate)" {
  # same script under two different events is fine
  _write_settings "${FIXTURE_DIR}/settings.json" \
    '{"hooks":{
       "PreToolUse":[{"hooks":[{"type":"command","command":"bash scripts/some-hook.sh"}]}],
       "PostToolUse":[{"hooks":[{"type":"command","command":"bash scripts/some-hook.sh"}]}]
     }}'
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_success
}

@test "fail with clear message on malformed settings.json" {
  printf 'this is not json at all\n' > "${FIXTURE_DIR}/settings.json"
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "malformed JSON"
}

@test "fail with clear message on malformed fragment JSON" {
  _write_settings "${FIXTURE_DIR}/settings.json" '{}'
  printf '{ bad json\n' > "${FIXTURE_FRAGS}/10.json"
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "malformed JSON"
}

@test "fail when same basename wired twice inside one fragment file" {
  # Within a single fragment: two entries for the same script under the same event = real dup.
  _write_settings "${FIXTURE_DIR}/settings.json" '{}'
  _write_settings "${FIXTURE_FRAGS}/only.json" \
    '{"hooks":{"SessionStart":[
       {"type":"command","command":"bash ~/.claude/scripts/cast-session-start-hook.sh"},
       {"type":"command","command":"bash ~/.claude/scripts/cast-session-start-hook.sh"}
     ]}}'
  run env CAST_SETTINGS_FILE="${FIXTURE_DIR}/settings.json" \
         CAST_SETTINGS_DIR="${FIXTURE_FRAGS}" \
         python3 "${LINT_PY}"
  assert_failure
  assert_output --partial "cast-session-start-hook.sh"
  assert_output --partial "only.json"
}
