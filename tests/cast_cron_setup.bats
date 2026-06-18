#!/usr/bin/env bats
# cast_cron_setup.bats — Tests for cast-cron-setup.sh security fixes
#
# Coverage:
#   (a) make_cron_line produces a crontab entry that references a script file,
#       NOT an inline -p prompt
#   (b) the generated script file exists and is executable after install

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CRON_SH="$REPO_DIR/scripts/cast-cron-setup.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Directories the script creates
  mkdir -p "${HOME}/.claude/logs"
  mkdir -p "${HOME}/.cast/cron"

  # Stub crontab to avoid touching the real crontab
  mkdir -p "${HOME}/bin"
  cat > "${HOME}/bin/crontab" <<'STUB'
#!/bin/bash
# Stub: record what was passed to crontab -
if [[ "${1:-}" == "-l" ]]; then
  # Return empty crontab
  exit 0
fi
if [[ "${1:-}" == "-" ]]; then
  # Record piped-in crontab content
  cat > "${HOME}/.stub-crontab"
  exit 0
fi
exit 0
STUB
  chmod +x "${HOME}/bin/crontab"
  export PATH="${HOME}/bin:$PATH"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# (a) make_cron_line — crontab entry references a script file, not an inline prompt
# We verify this by running install and inspecting the written crontab content.
# ---------------------------------------------------------------------------

@test "install: crontab entry for morning references .sh script file, not inline -p" {
  run env CAST_JARVIS_LOCAL=1 bash "$CRON_SH"
  assert_success
  # The stub crontab captures what was piped in
  assert [ -f "${HOME}/.stub-crontab" ]
  run grep 'morning' "${HOME}/.stub-crontab"
  assert_success
  assert_output --partial ".cast/cron/morning.sh"
}

@test "install: crontab entry does NOT embed inline prompt text" {
  run bash "$CRON_SH"
  assert_success
  assert [ -f "${HOME}/.stub-crontab" ]
  run grep -F "Generate today" "${HOME}/.stub-crontab"
  # grep must find NO match — expect failure
  assert_failure
}

@test "install: crontab entry does NOT contain any hardcoded /Users/ path" {
  run bash "$CRON_SH"
  assert_success
  assert [ -f "${HOME}/.stub-crontab" ]
  run grep -E '/Users/[a-zA-Z]' "${HOME}/.stub-crontab"
  assert_failure
}

# ---------------------------------------------------------------------------
# (b) Generated script file exists and is executable after install
# ---------------------------------------------------------------------------

@test "install: generates morning.sh script file" {
  run env CAST_JARVIS_LOCAL=1 bash "$CRON_SH"
  assert_success
  assert [ -f "${HOME}/.cast/cron/morning.sh" ]
}

@test "install: generated morning.sh is executable" {
  run env CAST_JARVIS_LOCAL=1 bash "$CRON_SH"
  assert_success
  assert [ -x "${HOME}/.cast/cron/morning.sh" ]
}

@test "install: generates tidy.sh script file" {
  run bash "$CRON_SH"
  assert_success
  assert [ -f "${HOME}/.cast/cron/tidy.sh" ]
}

@test "install: all 7 cron script files are generated" {
  run env CAST_JARVIS_LOCAL=1 bash "$CRON_SH"
  assert_success
  local count
  count=$(ls "${HOME}/.cast/cron/"*.sh 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 7 ]
}

# ---------------------------------------------------------------------------
# Regression: tidy.sh uses ${HOME} not hardcoded path
# ---------------------------------------------------------------------------

@test "tidy.sh: uses \${HOME}/.local/bin/cast not any hardcoded /Users/ path" {
  run bash "$CRON_SH"
  assert_success
  run grep -E '/Users/[a-zA-Z]' "${HOME}/.cast/cron/tidy.sh"
  assert_failure
}

@test "tidy.sh: references cast tidy via \${HOME}" {
  run bash "$CRON_SH"
  assert_success
  run grep -F '${HOME}/.local/bin/cast' "${HOME}/.cast/cron/tidy.sh"
  assert_success
}

# ---------------------------------------------------------------------------
# Default-behavior coverage: sunset guard (CAST_JARVIS_LOCAL not set)
# Proves jarvis/noisy-infra jobs stay off unless explicitly opted in.
# ---------------------------------------------------------------------------

@test "install (default): sunset scripts are NOT generated without CAST_JARVIS_LOCAL" {
  run bash "$CRON_SH"
  assert_success
  assert [ ! -f "${HOME}/.cast/cron/morning.sh" ]
  assert [ ! -f "${HOME}/.cast/cron/summary.sh" ]
  assert [ ! -f "${HOME}/.cast/cron/cron-health.sh" ]
}

@test "install (default): generates exactly 4 non-sunset scripts without CAST_JARVIS_LOCAL" {
  run bash "$CRON_SH"
  assert_success
  local count
  count=$(ls "${HOME}/.cast/cron/"*.sh 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 4 ]
}

@test "install (default): morning is not scheduled in crontab without CAST_JARVIS_LOCAL" {
  run bash "$CRON_SH"
  assert_success
  # non-sunset jobs still write the stub-crontab
  assert [ -f "${HOME}/.stub-crontab" ]
  run grep 'morning' "${HOME}/.stub-crontab"
  assert_failure
}
