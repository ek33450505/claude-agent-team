#!/usr/bin/env bats
# cast-wipe-canary.bats — Tests for scripts/cast-wipe-canary.sh
#
# Coverage:
#   (a) fast path   — ~/.claude exists → exit 0, no incident dir written
#   (b) trigger path — ~/.claude absent → incident dir created with processes.txt
#                      + manifest.txt; ~/.claude is NEVER recreated
#   (c) path safety  — incident dir is outside $HOME/.claude
#   (d) subprocess guard — CLAUDE_SUBPROCESS=1 → exit 0, nothing written
#
# HARD RULES enforced here:
#   - Isolated temp HOME via setup_temp_home / teardown_temp_home (never real $HOME)
#   - CAST_CANARY_FAST_CAPTURE=1 on every run (skips lsof + log show for speed)
#   - Separate CAST_INCIDENT_DIR so incident data never touches $HOME/.claude

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-wipe-canary.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

  # GUI isolation: stub out desktop notification tools so that the trigger path
  # (which calls osascript on the wipe path, script lines ~123-129) does NOT
  # fire a real macOS notification during the test suite.
  STUB_BIN_DIR="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN_DIR}"
  for _stub_cmd in osascript notify-send terminal-notifier; do
    printf '#!/bin/sh\nexit 0\n' > "${STUB_BIN_DIR}/${_stub_cmd}"
    chmod +x "${STUB_BIN_DIR}/${_stub_cmd}"
  done
  export PATH="${STUB_BIN_DIR}:${PATH}"
  export STUB_BIN_DIR

  # Separate incident dir OUTSIDE HOME — the canary writes here
  TEST_INCIDENT_DIR="$(mktemp -d)"
  export TEST_INCIDENT_DIR
}

teardown() {
  teardown_temp_home
  [[ -n "${TEST_INCIDENT_DIR:-}" ]] && rm -rf "${TEST_INCIDENT_DIR}"
}

# ---------------------------------------------------------------------------
# (a) Fast path: ~/.claude exists → exit 0, no incident dir written
# ---------------------------------------------------------------------------

@test "fast path: exits 0 when HOME/.claude exists" {
  mkdir -p "${HOME}/.claude"

  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success
}

@test "fast path: no incident dir created when HOME/.claude exists" {
  mkdir -p "${HOME}/.claude"

  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  # Incident dir parent should be empty (no wipe-* subdirs)
  local wipe_count
  wipe_count="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d | wc -l | tr -d ' ')"
  [ "${wipe_count}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (b) Trigger path: ~/.claude absent → incident dir created; ~/.claude NOT recreated
# ---------------------------------------------------------------------------

@test "trigger path: exits 0 when HOME/.claude is absent" {
  # HOME is a fresh temp dir from setup_temp_home — no .claude subdir

  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success
}

@test "trigger path: creates a wipe-* incident subdir when HOME/.claude is absent" {
  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success

  local wipe_count
  wipe_count="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d | wc -l | tr -d ' ')"
  [ "${wipe_count}" -ge 1 ]
}

@test "trigger path: processes.txt is present in incident dir" {
  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success

  local incident_dir
  incident_dir="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d | head -1)"
  [ -f "${incident_dir}/processes.txt" ]
}

@test "trigger path: manifest.txt is present in incident dir" {
  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success

  local incident_dir
  incident_dir="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d | head -1)"
  [ -f "${incident_dir}/manifest.txt" ]
}

@test "trigger path: manifest.txt records claude_dir_exists: no" {
  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success

  local incident_dir
  incident_dir="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d | head -1)"
  grep -q 'claude_dir_exists:.*no' "${incident_dir}/manifest.txt"
}

@test "trigger path: NEVER recreates HOME/.claude" {
  # Precondition: .claude must not exist
  [ ! -d "${HOME}/.claude" ]

  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success

  # The canary must not have created ~/.claude
  [ ! -d "${HOME}/.claude" ]
}

# ---------------------------------------------------------------------------
# (c) Path safety: incident dir is outside HOME/.claude
# ---------------------------------------------------------------------------

@test "path safety: incident dir is not inside HOME/.claude" {
  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success

  local incident_dir
  incident_dir="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d | head -1)"

  # incident_dir must NOT start with HOME/.claude
  case "${incident_dir}" in
    "${HOME}/.claude"*) false ;;  # fail the test if inside .claude
    *) true ;;
  esac
}

@test "path safety: incident dir is under CAST_INCIDENT_DIR" {
  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         bash "${SCRIPT}"

  assert_success

  local incident_dir
  incident_dir="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d | head -1)"

  # incident_dir must start with TEST_INCIDENT_DIR
  case "${incident_dir}" in
    "${TEST_INCIDENT_DIR}/"*) true ;;
    *) false ;;
  esac
}

# ---------------------------------------------------------------------------
# (d) Subprocess guard: CLAUDE_SUBPROCESS=1 → exit 0, nothing written
# ---------------------------------------------------------------------------

@test "subprocess guard: exits 0 when CLAUDE_SUBPROCESS=1" {
  # Trigger conditions (no .claude) — but guard fires first

  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         CLAUDE_SUBPROCESS=1 \
         bash "${SCRIPT}"

  assert_success
}

@test "subprocess guard: no incident dir created when CLAUDE_SUBPROCESS=1" {
  run env HOME="${HOME}" \
         CAST_INCIDENT_DIR="${TEST_INCIDENT_DIR}" \
         CAST_CANARY_FAST_CAPTURE=1 \
         CLAUDE_SUBPROCESS=1 \
         bash "${SCRIPT}"

  local wipe_count
  wipe_count="$(find "${TEST_INCIDENT_DIR}" -maxdepth 1 -name 'wipe-*' -type d 2>/dev/null | wc -l | tr -d ' ')"
  [ "${wipe_count}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (e) Pillar-2: plist ProgramArguments script path is outside ~/.claude
# ---------------------------------------------------------------------------

@test "pillar-2: plist ProgramArguments script path is outside ~/.claude blast radius" {
  local plist="${REPO_DIR}/macos/cast-wipe-canary.plist"
  [ -f "${plist}" ]

  # Must reference the off-blast-radius location
  grep -q 'Library/Application Support/cast/bin/cast-wipe-canary.sh' "${plist}"

  # Must NOT point into the blast-radius (~/.claude)
  run grep '\.claude.*cast-wipe-canary\.sh' "${plist}"
  assert_failure
}
