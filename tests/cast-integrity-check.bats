#!/usr/bin/env bats
# cast-integrity-check.bats — Tests for scripts/cast-integrity-check.sh
#
# Coverage:
#   (a) first run, absent baseline → baseline created with warn count; no notification; log written
#   (b) second run, warn count unchanged → no notification; baseline unchanged
#   (c) warn count increases vs baseline → notification stub invoked; baseline updated
#   (d) warn count decreases vs baseline → no notification; baseline updated downward
#   (e) cast binary missing/non-executable → exits 0 gracefully; error logged
#
# R2 dogfood rule: PATH-shim osascript with a no-op stub so real macOS desktop
# notifications never fire during tests.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-integrity-check.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home   # sets HOME to a temp dir; exports ORIG_HOME

  # GUI isolation: stub osascript and notify-send with no-ops so no real
  # desktop notification fires during the test suite (R2 dogfood rule).
  STUB_BIN_DIR="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN_DIR}"

  # osascript stub: records invocation to a marker file, then exits 0.
  cat > "${STUB_BIN_DIR}/osascript" <<'STUB'
#!/bin/sh
MARKER="${BATS_TEST_TMPDIR}/osascript-called"
echo "called: $*" >> "${MARKER}"
exit 0
STUB
  chmod +x "${STUB_BIN_DIR}/osascript"

  for _cmd in notify-send terminal-notifier; do
    printf '#!/bin/sh\nexit 0\n' > "${STUB_BIN_DIR}/${_cmd}"
    chmod +x "${STUB_BIN_DIR}/${_cmd}"
  done

  export PATH="${STUB_BIN_DIR}:${PATH}"
  export STUB_BIN_DIR

  # Test-local paths so the script writes into isolated dirs.
  export CAST_INTEGRITY_LOG="${BATS_TEST_TMPDIR}/integrity.log"
  export CAST_INTEGRITY_BASELINE="${BATS_TEST_TMPDIR}/warn-baseline"

  # Create a controllable fake `cast` binary on PATH.
  # FAKE_WARN_COUNT controls what it emits (default: 1).
  export FAKE_WARN_COUNT="${FAKE_WARN_COUNT:-1}"
  cat > "${STUB_BIN_DIR}/cast" <<'CASTEOF'
#!/bin/sh
WARN="${FAKE_WARN_COUNT:-1}"
echo "integrity: 3 ok, ${WARN} warn, 2 info"
exit 0
CASTEOF
  chmod +x "${STUB_BIN_DIR}/cast"

  # Notification marker file path (used in assertions)
  NOTIFY_MARKER="${BATS_TEST_TMPDIR}/osascript-called"
  export NOTIFY_MARKER
}

teardown() {
  teardown_temp_home
}

# Helper: run the script with the current env.
_run_script() {
  run env HOME="${HOME}" \
         PATH="${PATH}" \
         CAST_INTEGRITY_LOG="${CAST_INTEGRITY_LOG}" \
         CAST_INTEGRITY_BASELINE="${CAST_INTEGRITY_BASELINE}" \
         FAKE_WARN_COUNT="${FAKE_WARN_COUNT}" \
         bash "${SCRIPT}"
}

# ---------------------------------------------------------------------------
# (a) First run: absent baseline → baseline created, no notification, log written
# ---------------------------------------------------------------------------

@test "first run: exits 0 when baseline is absent" {
  [ ! -f "${CAST_INTEGRITY_BASELINE}" ]
  _run_script
  assert_success
}

@test "first run: creates baseline file with the warn count" {
  FAKE_WARN_COUNT=2 _run_script
  [ -f "${CAST_INTEGRITY_BASELINE}" ]
  local stored
  stored="$(cat "${CAST_INTEGRITY_BASELINE}")"
  [ "${stored}" = "2" ]
}

@test "first run: does NOT invoke osascript (no notification)" {
  _run_script
  [ ! -f "${NOTIFY_MARKER}" ]
}

@test "first run: writes a timestamped block to the audit log" {
  _run_script
  [ -f "${CAST_INTEGRITY_LOG}" ]
  grep -q "integrity:" "${CAST_INTEGRITY_LOG}"
}

# ---------------------------------------------------------------------------
# (b) Second run: warn count unchanged → no notification
# ---------------------------------------------------------------------------

@test "second run unchanged: no notification fired" {
  FAKE_WARN_COUNT=1 _run_script   # establish baseline
  rm -f "${NOTIFY_MARKER}"        # reset marker
  FAKE_WARN_COUNT=1 _run_script   # re-run with same count
  [ ! -f "${NOTIFY_MARKER}" ]
}

@test "second run unchanged: exits 0" {
  FAKE_WARN_COUNT=1 _run_script
  FAKE_WARN_COUNT=1 _run_script
  assert_success
}

# ---------------------------------------------------------------------------
# (c) Warn count increases → notification invoked; baseline updated
# ---------------------------------------------------------------------------

@test "regression: notification invoked when warn count rises" {
  FAKE_WARN_COUNT=1 _run_script   # baseline = 1
  rm -f "${NOTIFY_MARKER}"
  FAKE_WARN_COUNT=3 _run_script   # 3 > 1 → regression
  [ -f "${NOTIFY_MARKER}" ]
}

@test "regression: baseline updated to new (higher) warn count" {
  FAKE_WARN_COUNT=1 _run_script
  FAKE_WARN_COUNT=3 _run_script
  local stored
  stored="$(cat "${CAST_INTEGRITY_BASELINE}")"
  [ "${stored}" = "3" ]
}

@test "regression: exits 0 even on regression" {
  FAKE_WARN_COUNT=1 _run_script
  FAKE_WARN_COUNT=3 _run_script
  assert_success
}

# ---------------------------------------------------------------------------
# (d) Warn count decreases → no notification; baseline updated downward
# ---------------------------------------------------------------------------

@test "improvement: no notification when warn count decreases" {
  FAKE_WARN_COUNT=3 _run_script   # baseline = 3
  rm -f "${NOTIFY_MARKER}"
  FAKE_WARN_COUNT=1 _run_script   # 1 < 3 → improvement
  [ ! -f "${NOTIFY_MARKER}" ]
}

@test "improvement: baseline updated to lower warn count" {
  FAKE_WARN_COUNT=3 _run_script
  FAKE_WARN_COUNT=1 _run_script
  local stored
  stored="$(cat "${CAST_INTEGRITY_BASELINE}")"
  [ "${stored}" = "1" ]
}

# ---------------------------------------------------------------------------
# (e) cast binary missing/non-executable → exits 0 gracefully; error logged
# ---------------------------------------------------------------------------

@test "missing cast: exits 0 gracefully" {
  # Build a PATH that contains only GUI stubs (osascript etc.) but NO cast binary.
  # Keep /bin:/usr/bin so bash, grep, sed, etc. remain available.
  NO_CAST_BIN="${BATS_TEST_TMPDIR}/no-cast-bin"
  mkdir -p "${NO_CAST_BIN}"
  for _cmd in osascript notify-send terminal-notifier; do
    printf '#!/bin/sh\nexit 0\n' > "${NO_CAST_BIN}/${_cmd}"
    chmod +x "${NO_CAST_BIN}/${_cmd}"
  done

  run env HOME="${HOME}" \
         PATH="${NO_CAST_BIN}:/bin:/usr/bin" \
         CAST_INTEGRITY_LOG="${CAST_INTEGRITY_LOG}" \
         CAST_INTEGRITY_BASELINE="${CAST_INTEGRITY_BASELINE}" \
         bash "${SCRIPT}"
  assert_success
}

@test "missing cast: writes error to log" {
  NO_CAST_BIN="${BATS_TEST_TMPDIR}/no-cast-bin2"
  mkdir -p "${NO_CAST_BIN}"
  for _cmd in osascript notify-send terminal-notifier; do
    printf '#!/bin/sh\nexit 0\n' > "${NO_CAST_BIN}/${_cmd}"
    chmod +x "${NO_CAST_BIN}/${_cmd}"
  done

  run env HOME="${HOME}" \
         PATH="${NO_CAST_BIN}:/bin:/usr/bin" \
         CAST_INTEGRITY_LOG="${CAST_INTEGRITY_LOG}" \
         CAST_INTEGRITY_BASELINE="${CAST_INTEGRITY_BASELINE}" \
         bash "${SCRIPT}"

  [ -f "${CAST_INTEGRITY_LOG}" ]
  grep -q "\[ERROR\]" "${CAST_INTEGRITY_LOG}"
}

@test "non-executable cast: exits 0 gracefully" {
  # Place a non-executable 'cast' file at the front of PATH so command -v finds
  # it but the executable check ([ ! -x ]) fails.
  BAD_BIN="${BATS_TEST_TMPDIR}/bad-bin"
  mkdir -p "${BAD_BIN}"
  printf '#!/bin/sh\nexit 0\n' > "${BAD_BIN}/cast"
  # deliberately NOT chmod +x — leave it non-executable

  NO_CAST_STUBS="${BATS_TEST_TMPDIR}/nc-stubs"
  mkdir -p "${NO_CAST_STUBS}"
  for _cmd in osascript notify-send terminal-notifier; do
    printf '#!/bin/sh\nexit 0\n' > "${NO_CAST_STUBS}/${_cmd}"
    chmod +x "${NO_CAST_STUBS}/${_cmd}"
  done

  run env HOME="${HOME}" \
         PATH="${BAD_BIN}:${NO_CAST_STUBS}:/bin:/usr/bin" \
         CAST_INTEGRITY_LOG="${CAST_INTEGRITY_LOG}" \
         CAST_INTEGRITY_BASELINE="${CAST_INTEGRITY_BASELINE}" \
         bash "${SCRIPT}"
  assert_success
}
